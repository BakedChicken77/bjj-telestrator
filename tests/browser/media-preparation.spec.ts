import playwright from '../../frontend/node_modules/@playwright/test/index.mjs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const { test, expect } = playwright;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

for (const viewport of [{ width: 1280, height: 720 }, { width: 390, height: 844 }]) {
  test(`tracked import, cancel and repair retain the review at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await page.goto('/');
    // Hold only this request to exercise cancellation during source transfer.
    // The job creation, cancellation, status and subsequent media pipeline are real.
    let release!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    await page.route('**/api/projects/import', async (route) => { await held; await route.abort(); }, { times: 1 });
    const reservation = page.waitForResponse((r) => r.url().endsWith('/api/import-jobs'));
    await page.getByLabel('Import video', { exact: true }).setInputFiles(path.join(root, 'tests/generated/silent.mp4'));
    const abandoned = await (await reservation).json();
    await page.getByRole('button', { name: 'Cancel preparation', exact: true }).click();
    await expect.poll(async () => (await (await page.request.get(`/api/media-jobs/${abandoned.jobId}`)).json()).status).toBe('cancelled');
    release();
    await expect(page.getByLabel('Import video', { exact: true })).toBeEnabled();
    expect((await page.request.get(`/api/projects/${abandoned.projectId}`)).status()).toBe(404);
    const imported = page.waitForResponse((r) => r.url().endsWith('/api/projects/import') && r.request().method() === 'POST');
    await page.getByLabel('Import video', { exact: true }).setInputFiles(path.join(root, 'tests/generated/rotated.mov'));
    const project = await (await imported).json();
    await expect(page.locator('video')).toBeVisible();
    const oldURL = await page.locator('video').getAttribute('src');
    await page.getByRole('button', { name: 'Arrow', exact: true }).click();
    const picture = await page.getByTestId('video-picture').boundingBox();
    expect(picture).toBeTruthy();
    await page.mouse.move(picture!.x + picture!.width * .2, picture!.y + picture!.height * .3);
    await page.mouse.down();
    await page.mouse.move(picture!.x + picture!.width * .6, picture!.y + picture!.height * .6, { steps: 6 });
    await page.mouse.up();
    await page.getByRole('button', { name: 'Projects', exact: true }).click();
    const before = await (await page.request.get(`/api/projects/${project.projectId}`)).json();
    expect(before.annotations).toHaveLength(1);
    const repair = page.waitForResponse((r) => r.url().endsWith(`/api/projects/${project.projectId}/proxy-jobs`));
    await page.getByRole('button', { name: 'Repair preview', exact: true }).click();
    const job = await (await repair).json();
    await expect.poll(async () => (await (await page.request.get(`/api/media-jobs/${job.jobId}`)).json()).status).toBe('completed');
    await expect(page.locator('video')).toBeVisible();
    await expect(page.locator('video')).not.toHaveAttribute('src', oldURL!);
    const after = await (await page.request.get(`/api/projects/${project.projectId}`)).json();
    expect(after.projectId).toBe(before.projectId);
    expect(after.revision).toBe(before.revision + 1);
    expect(after.annotations).toEqual(before.annotations);
    expect(after.voiceovers).toEqual(before.voiceovers);
    expect(after.source).toEqual(before.source);
    expect(after.proxy.displayWidth).toBe(project.source.displayWidth);
    expect(after.proxy.displayHeight).toBe(project.source.displayHeight);
    await page.reload();
    await expect(page.locator('video')).toBeVisible();
    await expect.poll(() => page.locator('video').evaluate((v: HTMLVideoElement) => v.readyState)).toBeGreaterThanOrEqual(2);
    await page.getByRole('button', { name: 'Export video', exact: true }).click();
    await page.getByRole('button', { name: 'Render MP4', exact: true }).click();
    const link = page.getByRole('link', { name: 'Download MP4 ↓', exact: true });
    await expect(link).toBeVisible();
    const output = await page.request.get((await link.getAttribute('href'))!);
    expect(output.ok()).toBeTruthy();
    expect(output.headers()['content-type']).toContain('video/mp4');
    expect((await output.body()).length).toBeGreaterThan(1000);
    expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)).toBe(false);
  });
}
