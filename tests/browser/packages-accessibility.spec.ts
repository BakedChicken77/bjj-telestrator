import playwright from '../../frontend/node_modules/@playwright/test/index.mjs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { test, expect } = playwright;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

test('a lost backup acknowledgement recovers the same durable request without duplication', async ({ page }) => {
  await page.goto('/');
  await page.getByLabel('Import video', { exact: true }).setInputFiles(path.join(root, 'tests/generated/silent.mp4'));
  await expect(page.locator('video')).toBeVisible();
  await page.getByRole('button', { name: 'Projects', exact: true }).click();
  let created = '', creates = 0, connected = false;
  await page.route('**/api/package-jobs', async (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    creates++;
    created = route.request().postDataJSON().requestId;
    const accepted = await route.fetch();
    expect(accepted.status()).toBe(202);
    await route.abort('connectionreset'); // Real service accepted; only acknowledgement is lost.
  });
  await page.route(/\/api\/package-jobs\/[0-9a-f-]{36}$/, async (route) => {
    if (!connected) return route.abort('connectionreset');
    return route.continue();
  });
  await page.getByRole('button', { name: 'Back up editable project', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Retry package status', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Back up editable project', exact: true })).toBeDisabled();
  expect(await page.evaluate(() => localStorage.getItem('bjj:packageJob'))).toBe(created);
  connected = true;
  await page.getByRole('button', { name: 'Retry package status', exact: true }).click();
  await expect(page.getByRole('link', { name: 'Download editable backup', exact: true })).toBeVisible();
  expect(creates).toBe(1);
  expect((await (await page.request.get(`/api/package-jobs/${created}`)).json()).status).toBe('completed');
});

for (const viewport of [{ width: 1280, height: 720 }, { width: 390, height: 844 }]) {
  test(`editable package and non-drag controls at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'reduce' });
    await page.goto('/');
    const imported = page.waitForResponse((r) => r.url().endsWith('/api/projects/import') && r.request().method() === 'POST');
    const originalPath = path.join(root, 'tests/generated/silent.mp4');
    const sourceHash = createHash('sha256').update(fs.readFileSync(originalPath)).digest('hex');
    await page.getByLabel('Import video', { exact: true }).setInputFiles(originalPath);
    const project = await (await imported).json();
    await expect(page.locator('video')).toBeVisible();
    if (viewport.width < 1000) await page.getByRole('button', { name: 'Properties & settings', exact: true }).click();
    await page.getByLabel('New annotation type', { exact: true }).selectOption('rectangle');
    await page.getByRole('button', { name: 'Add annotation at playhead', exact: true }).focus();
    await page.keyboard.press('Space'); // Focused button activation must not start video.
    await expect(page.getByLabel('X (%)', { exact: true })).toHaveValue('30');
    expect(await page.locator('video').evaluate((video: HTMLVideoElement) => video.paused)).toBe(true);
    await page.getByLabel('X (%)', { exact: true }).fill('20');
    await page.getByLabel('X (%)', { exact: true }).press('Enter');
    await page.getByLabel('Width (%)', { exact: true }).fill('40');
    await page.getByLabel('Width (%)', { exact: true }).press('Enter');
    await page.getByLabel('Start time', { exact: true }).fill('0.5');
    await page.getByLabel('Start time', { exact: true }).press('Enter');
    await page.getByLabel('End time', { exact: true }).fill('2');
    await page.getByLabel('End time', { exact: true }).press('Enter');
    await page.getByRole('button', { name: 'Move right 1%', exact: true }).click();
    await expect(page.getByLabel('X (%)', { exact: true })).toHaveValue('21');
    await page.keyboard.press('Control+z');
    await expect(page.getByLabel('X (%)', { exact: true })).toHaveValue('20');
    for (const [type, field, value] of [
      ['line', 'End X (%)', '65'], ['arrow', 'Start X (%)', '25'],
      ['ellipse', 'Center X (%)', '55'], ['freehand', 'Point X (%)', '25'],
      ['text', 'X (%)', '25'],
    ]) {
      await page.getByLabel('New annotation type', { exact: true }).selectOption(type!);
      await page.getByRole('button', { name: 'Add annotation at playhead', exact: true }).click();
      await page.getByLabel(field!, { exact: true }).fill(value!);
      await page.getByLabel(field!, { exact: true }).press('Enter');
      await expect(page.getByLabel(field!, { exact: true })).toHaveValue(value!);
    }
    await page.getByLabel('Text content', { exact: true }).fill('Ajuste a posição');
    await page.getByLabel('Text content', { exact: true }).press('Tab');
    await page.getByRole('button', { name: 'Audio & voiceovers', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Close audio controls', exact: true })).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('button', { name: 'Audio & voiceovers', exact: true })).toBeFocused();
    await page.getByRole('button', { name: 'Projects', exact: true }).click();
    await expect(page.locator('dialog:modal')).toBeVisible();
    await page.keyboard.press('Tab');
    expect(await page.evaluate(() => document.querySelector('dialog:modal')?.contains(document.activeElement))).toBe(true);
    await page.getByText('Appearance and keyboard help', { exact: true }).click();
    await page.getByLabel('Theme', { exact: true }).selectOption('dark');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await page.getByLabel('Theme', { exact: true }).selectOption('light');
    await page.getByLabel('Larger editor text', { exact: true }).check();
    await expect(page.locator('html')).toHaveAttribute('data-large-text', 'true');
    await page.screenshot({ path: path.join(root, `.ci-artifacts/packages-${viewport.width}-large.png`) });
    const overflow = await page.evaluate(() => ({
      width: document.documentElement.scrollWidth,
      viewport: innerWidth,
      elements: [...document.querySelectorAll('*')].map((element) => ({
        tag: element.tagName, class: element.className, parent: element.parentElement?.outerHTML.slice(0, 1000),
        right: element.getBoundingClientRect().right,
        width: element.getBoundingClientRect().width,
      })).filter((box) => box.right > innerWidth + 1 && box.width > 0).slice(0, 20),
    }));
    expect(overflow.width, JSON.stringify(overflow)).toBeLessThanOrEqual(overflow.viewport);
    await page.getByLabel('Larger editor text', { exact: true }).uncheck();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('button', { name: 'Projects', exact: true })).toBeFocused();
    await page.getByRole('button', { name: 'Projects', exact: true }).click();
    const saved = await (await page.request.get(`/api/projects/${project.projectId}`)).json();
    const cue = saved.annotations[0];
    expect(saved.annotations.map((item: { type: string }) => item.type)).toEqual(['rectangle', 'line', 'arrow', 'ellipse', 'freehand', 'text']);
    expect(saved.annotations[5].geometry.text).toBe('Ajuste a posição');
    expect(cue.geometry).toEqual({ x: .2, y: .3, width: .4, height: .3 });
    expect(cue.startSec).toBe(.5); expect(cue.endSec).toBe(2);
    await page.getByRole('button', { name: 'Back up editable project', exact: true }).click();
    const backupLink = page.getByRole('link', { name: 'Download editable backup', exact: true });
    await expect(backupLink).toBeVisible();
    const downloadEvent = page.waitForEvent('download');
    await backupLink.click();
    const backup = await downloadEvent;
    const backupPath = path.join(root, `tests/generated/review-${viewport.width}.bjjproj`);
    await backup.saveAs(backupPath);
    expect(fs.statSync(backupPath).size).toBeGreaterThan(fs.statSync(originalPath).size);
    await page.getByLabel('Restore project package', { exact: true }).setInputFiles(backupPath);
    const open = page.getByRole('button', { name: 'Open restored project', exact: true });
    await expect(open).toBeVisible();
    await open.click();
    await expect(page.locator('video')).toBeVisible();
    const restoredId = await page.evaluate(() => localStorage.getItem('bjj:lastProject'));
    expect(restoredId).not.toBe(project.projectId);
    const restored = await (await page.request.get(`/api/projects/${restoredId}`)).json();
    expect(restored.annotations[0].id).not.toBe(cue.id);
    expect(restored.annotations[0].geometry).toEqual(cue.geometry);
    expect(restored.annotations[0].startSec).toBe(.5);
    expect(restored.annotations.map((item: { geometry: unknown }) => item.geometry)).toEqual(saved.annotations.map((item: { geometry: unknown }) => item.geometry));
    const source = fs.readFileSync(path.join(process.env.BJJ_E2E_DATA_DIR ?? path.join(root, 'tests/generated/e2e-data'), 'projects', restoredId!, restored.source.asset));
    expect(createHash('sha256').update(source).digest('hex')).toBe(sourceHash);
    await page.getByRole('button', { name: 'Export video', exact: true }).click();
    await page.getByRole('button', { name: 'Render MP4', exact: true }).click();
    const mp4 = page.getByRole('link', { name: 'Download MP4' });
    await expect(mp4).toBeVisible({ timeout: 30000 });
    const movieEvent = page.waitForEvent('download'); await mp4.click();
    const movie = await movieEvent, moviePath = path.join(root, `tests/generated/restored-${viewport.width}.mp4`);
    await movie.saveAs(moviePath);
    const info = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', moviePath], { encoding: 'utf8' }));
    expect(info.streams.find((stream: {codec_type: string}) => stream.codec_type === 'video').codec_name).toBe('h264');
    expect(Math.abs(Number(info.format.duration) - 4)).toBeLessThanOrEqual(.1);
    await page.getByRole('button', { name: 'Close exports', exact: true }).click();
    if (viewport.width < 1000) await page.setViewportSize({ width: 844, height: 390 });
    await page.screenshot({ path: path.join(root, `.ci-artifacts/editor-${viewport.width}.png`) });
    expect(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)).toBe(false);
  });
}
