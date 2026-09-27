import playwright, { type Page } from '../../frontend/node_modules/@playwright/test/index.js';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { projectSchema, type Project } from '../../frontend/src/model';

const { test, expect } = playwright;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
test.use({ viewport: { width: 393, height: 852 }, hasTouch: true, isMobile: true, deviceScaleFactor: 3 });

// Real Chromium touch input and the real desktop media backend exercise the shared
// phone UI. Native Swift/AVFoundation execution is a separate Xcode acceptance gate.
async function openVideo(page: Page, filename: string): Promise<Project> {
  await page.goto('/');
  const imported = page.waitForResponse(r => r.url().endsWith('/api/projects/import') && r.request().method() === 'POST');
  await page.getByLabel('Import video', { exact: true }).setInputFiles(path.join(root, 'tests/generated', filename));
  const response = await imported;
  expect(response.ok(), await response.text()).toBeTruthy();
  const project = projectSchema.parse(await response.json());
  await expect.poll(() => page.locator('video').evaluate((v: HTMLVideoElement) => v.readyState)).toBeGreaterThanOrEqual(2);
  return project;
}
async function saved(page: Page, id: string) {
  return projectSchema.parse(await (await page.request.get(`/api/projects/${id}`)).json());
}
async function seek(page: Page, time: number) {
  await page.getByLabel('Seek video', { exact: true }).evaluate((input, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(input, String(value));
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }, time);
  await expect.poll(() => page.locator('video').evaluate((v: HTMLVideoElement) => v.currentTime)).toBeCloseTo(time, 2);
  await expect.poll(() => page.locator('video').evaluate((v: HTMLVideoElement) => v.seeking)).toBe(false);
}
async function drag(page: Page, from: [number, number], to: [number, number], secondFinger = false) {
  const session = await page.context().newCDPSession(page);
  const first = { id: 1, x: from[0], y: from[1] };
  await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [first] });
  if (secondFinger) {
    await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [first, { id: 2, x: to[0], y: to[1] }] });
  }
  for (let step = 1; step <= 12; step++) {
    await session.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{
      id: 1, x: from[0] + (to[0] - from[0]) * step / 12, y: from[1] + (to[1] - from[1]) * step / 12,
    }, ...(secondFinger ? [{ id: 2, x: to[0] - step, y: from[1] }] : [])] });
  }
  await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await session.detach();
}
async function draw(page: Page, tool: string, secondFinger = false) {
  await page.getByRole('button', { name: tool, exact: true }).tap();
  await page.getByTestId('video-picture').scrollIntoViewIfNeeded();
  const box = await page.getByTestId('video-picture').boundingBox();
  if (!box) throw new Error('The picture is not visible');
  await drag(page, [box.x + box.width * .2, box.y + box.height * .3], [box.x + box.width * .7, box.y + box.height * .65], secondFinger);
}
async function noPageOverflow(page: Page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(1);
}

test('phone touch drawing, trimming, undo, persistence and real MP4 export', async ({ page }, info) => {
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  const project = await openVideo(page, 'silent.mp4');
  await noPageOverflow(page);
  await seek(page, 1);
  await draw(page, 'Arrow', true);
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(1);
  const arrow = (await saved(page, project.projectId)).annotations[0];
  expect(arrow.type).toBe('arrow');
  if (arrow.type !== 'arrow') throw new Error('Expected an arrow');
  expect(arrow.geometry.x1).toBeCloseTo(.2, 2);
  expect(arrow.geometry.x2).toBeCloseTo(.7, 2);
  await page.getByRole('button', { name: 'Properties & settings', exact: true }).tap();
  await page.getByLabel('End time', { exact: true }).fill('00:03.000');
  await page.getByLabel('End time', { exact: true }).press('Tab');
  await expect.poll(async () => (await saved(page, project.projectId)).annotations[0].endSec).toBe(3);
  await page.getByRole('button', { name: 'Timeline', exact: true }).tap();
  await page.getByRole('button', { name: 'Fit', exact: true }).tap();
  const handle = page.getByRole('button', { name: 'Trim arrow end', exact: true });
  await handle.scrollIntoViewIfNeeded();
  const trim = await handle.boundingBox();
  if (!trim) throw new Error('The trim handle is missing');
  await drag(page, [trim.x + trim.width / 2, trim.y + trim.height / 2], [trim.x - 18, trim.y + trim.height / 2]);
  await expect.poll(async () => (await saved(page, project.projectId)).annotations[0].endSec).toBeLessThan(2.9);
  const end = (await saved(page, project.projectId)).annotations[0].endSec;
  await page.getByRole('button', { name: 'Undo', exact: true }).tap();
  await expect.poll(async () => (await saved(page, project.projectId)).annotations[0].endSec).toBe(3);
  await page.getByRole('button', { name: 'Redo', exact: true }).tap();
  await expect.poll(async () => (await saved(page, project.projectId)).annotations[0].endSec).toBe(end);
  await page.reload();
  await expect(page.getByTestId(`timeline-annotation-${arrow.id}`)).toBeAttached();
  await seek(page, 1.5);
  await expect(page.getByTestId('video-stage')).toHaveAttribute('data-visible-annotation-ids', new RegExp(arrow.id));
  await page.screenshot({ path: path.join(root, 'docs/iphone-layout.png') });
  await page.setViewportSize({ width: 852, height: 393 });
  await noPageOverflow(page);
  const rotated = (await saved(page, project.projectId)).annotations[0];
  expect(rotated.geometry).toEqual(arrow.geometry);
  await page.setViewportSize({ width: 393, height: 852 });
  await page.getByRole('button', { name: 'Project actions', exact: true }).tap();
  await page.getByRole('button', { name: 'Export video', exact: true }).tap();
  await page.getByRole('button', { name: 'Render MP4', exact: true }).tap();
  const link = page.getByRole('link', { name: /Download MP4/ }).first();
  await expect(link).toBeVisible({ timeout: 120_000 });
  const downloading = page.waitForEvent('download'); await link.tap();
  const download = await downloading;
  const output = info.outputPath('phone-layout-export.mp4'); await download.saveAs(output);
  expect(await download.failure()).toBeNull();
  const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', output], { encoding: 'utf8' }));
  expect(probe.streams[0].codec_name).toBe('h264');
  expect(Number(probe.format.duration)).toBeCloseTo(4, 1);
  expect(errors).toEqual([]);
});

test('portrait footage stays inside the phone picture while drawing and resizing the editor', async ({ page }) => {
  const project = await openVideo(page, 'portrait.mp4');
  await seek(page, .5);
  await draw(page, 'Ellipse');
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(1);
  const before = (await saved(page, project.projectId)).annotations[0];
  const box = await page.getByTestId('video-picture').boundingBox();
  expect(box!.height).toBeGreaterThan(box!.width);
  await page.setViewportSize({ width: 852, height: 393 });
  await noPageOverflow(page);
  expect((await saved(page, project.projectId)).annotations[0].geometry).toEqual(before.geometry);
  await page.setViewportSize({ width: 375, height: 667 });
  await noPageOverflow(page);
  await page.getByRole('button', { name: 'Properties & settings', exact: true }).tap();
  await expect(page.getByLabel('Stroke color', { exact: true })).toBeVisible();
});

async function reachable(page: Page, label: string) {
  const button = page.getByRole('button', { name: label, exact: true });
  await expect(button).toBeVisible();
  expect(await button.evaluate(element => {
    const r = element.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return r.width >= 44 && r.height >= 44 && r.top >= 0 && r.bottom <= innerHeight &&
      r.left >= 0 && r.right <= innerWidth && !!hit && element.contains(hit);
  })).toBe(true);
  await button.click({ trial: true });
}

test('audio controls remain dismissible above editor chrome at reported and small phone sizes', async ({ page }) => {
  const project = await openVideo(page, 'acceptance.mp4');
  // Populate a real long list of stored recordings; no synthetic DOM layout.
  const tone = execFileSync('ffmpeg', ['-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', '-f', 'wav', 'pipe:1']);
  for (let i = 0; i < 8; i++) {
    const response = await page.request.post(`/api/projects/${project.projectId}/voiceovers`, {
      multipart: { startSec: String(i), file: { name: 'take.wav', mimeType: 'audio/wav', buffer: tone } },
    });
    expect(response.ok(), await response.text()).toBeTruthy();
    project.voiceovers.push(await response.json());
  }
  expect((await page.request.put(`/api/projects/${project.projectId}`, { data: project })).ok()).toBeTruthy();
  await page.reload();
  for (const size of [{ width: 402, height: 874 }, { width: 874, height: 402 }, { width: 375, height: 667 }]) {
    await page.setViewportSize(size);
    await page.getByRole('button', { name: 'Audio & voiceovers', exact: true }).tap();
    const dialog = page.getByRole('dialog', { name: 'Audio & voiceovers', exact: true });
    await expect(dialog).toBeVisible();
    await reachable(page, 'Close audio controls');
    await dialog.locator('.audio-drawer-body').evaluate(e => { e.scrollTop = e.scrollHeight; });
    await expect(page.getByLabel('Voiceover 8 gain', { exact: true })).toBeInViewport();
    await reachable(page, 'Close audio controls');
    await page.getByRole('button', { name: 'Close audio controls', exact: true }).tap();
    await expect(dialog).not.toBeVisible();
    await expect(page.getByRole('button', { name: 'Audio & voiceovers', exact: true })).toBeFocused();
    await noPageOverflow(page);
  }
  await page.getByRole('button', { name: 'Audio & voiceovers', exact: true }).tap();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: 'Audio & voiceovers', exact: true })).not.toBeVisible();
  expect((await saved(page, project.projectId)).voiceovers).toHaveLength(8);
});

test('expanded video enlarges portrait footage and preserves canvas, playback position and undo through rotation', async ({ page }, info) => {
  await page.setViewportSize({ width: 402, height: 874 });
  const project = await openVideo(page, 'portrait.mp4');
  await seek(page, .5);
  await draw(page, 'Arrow');
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(1);
  const before = (await saved(page, project.projectId)).annotations[0];
  const video = await page.locator('video').elementHandle();
  const small = await page.getByTestId('video-picture').boundingBox();
  await page.getByRole('button', { name: 'Expand video', exact: true }).tap();
  await expect.poll(async () => (await page.getByTestId('video-picture').boundingBox())!.height).toBeGreaterThan(small!.height * 1.4);
  await reachable(page, 'Exit expanded video');
  await page.screenshot({ path: info.outputPath('expanded-portrait.png') });
  await draw(page, 'Ellipse');
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(2);
  await page.setViewportSize({ width: 874, height: 402 });
  await reachable(page, 'Exit expanded video');
  await expect(page.getByRole('button', { name: 'Record voiceover', exact: true })).toBeInViewport();
  await page.screenshot({ path: info.outputPath('expanded-landscape.png') });
  await page.setViewportSize({ width: 402, height: 874 });
  await page.getByRole('button', { name: 'Exit expanded video', exact: true }).tap();
  expect(await video!.evaluate(v => v === document.querySelector('video'))).toBe(true);
  expect(await page.locator('video').evaluate((v: HTMLVideoElement) => v.currentTime)).toBeCloseTo(.5, 2);
  await page.getByRole('button', { name: 'Undo', exact: true }).tap();
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(1);
  expect((await saved(page, project.projectId)).annotations[0].geometry).toEqual(before.geometry);
  await page.getByRole('button', { name: 'Redo', exact: true }).tap();
  await expect.poll(async () => (await saved(page, project.projectId)).annotations.length).toBe(2);
  await noPageOverflow(page);
});
