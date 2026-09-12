import playwright, { type Page } from '../../frontend/node_modules/@playwright/test/index.mjs';
const { test, expect } = playwright;
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
async function imported(page: Page) {
  await page.goto('/');
  const response = page.waitForResponse((r) => r.url().endsWith('/api/projects/import') && r.request().method() === 'POST');
  await page.getByLabel('Import video', { exact: true }).setInputFiles(path.join(root, 'tests/generated/silent.mp4'));
  const project = await (await response).json();
  await expect(page.locator('video')).toBeVisible();
  return project;
}
async function rename(page: Page, name: string) {
  await page.getByLabel('Project name', { exact: true }).fill(name);
  await page.getByLabel('Project name', { exact: true }).press('Tab');
}
test('two editors preserve conflicting revisions and recover an independent real project', async ({ page, context }) => {
  const p = await imported(page);
  const other = await context.newPage();
  await other.goto('/');
  await expect(other.getByLabel('Project name', { exact: true })).toHaveValue(p.projectName);
  await rename(other, 'Newer confirmed review');
  await expect(other.getByTestId('save-status')).toHaveText('Saved');
  await expect.poll(async () => (await (await page.request.get(`/api/projects/${p.projectId}`)).json()).projectName).toBe('Newer confirmed review');
  await rename(page, 'My conflicting edits');
  await expect(page.getByTestId('save-status')).toHaveText('Save conflict');
  await expect(page.getByLabel('Save conflict recovery')).toBeVisible();
  const copyResponse = page.waitForResponse((r) => r.url().endsWith('/recover-copy'));
  await page.getByRole('button', { name: 'Recover my edits as a copy', exact: true }).click();
  const copy = await (await copyResponse).json();
  expect(copy.projectId).not.toBe(p.projectId);
  expect(copy.projectName).toContain('My conflicting edits');
  expect(copy.revision).toBe(1);
  await expect(page.getByLabel('Project name', { exact: true })).toHaveValue(copy.projectName);
  expect((await (await page.request.get(`/api/projects/${p.projectId}`)).json()).projectName).toBe('Newer confirmed review');
  await other.close();
});
test('failed save survives reload and support preview contains only allowlisted diagnostics', async ({ page }) => {
  const p = await imported(page);
  const endpoint = `**/api/projects/${p.projectId}`;
  await page.route(endpoint, (route) => route.request().method() === 'PUT' ? route.abort('failed') : route.continue());
  await rename(page, 'Private athlete name NEVER_IN_DIAGNOSTICS');
  await expect(page.getByTestId('save-status')).toHaveText('Save failed');
  await page.getByRole('button', { name: 'Inspect support summary' }).click();
  const summary = await page.locator('dialog pre').innerText();
  const report = JSON.parse(summary);
  expect(report.includesMedia).toBe(false);
  expect(summary).not.toContain(p.projectId);
  expect(summary).not.toContain('NEVER_IN_DIAGNOSTICS');
  expect(summary).not.toContain(p.source.asset);
  await page.keyboard.press('Escape');
  await expect(page.locator('dialog')).toHaveCount(0);
  const drafts = await page.evaluate(() => Object.keys(localStorage).filter((key) => key.startsWith('bjj:recovery:')));
  expect(drafts.length).toBeGreaterThan(0);
  page.on('dialog', (dialog) => dialog.accept());
  await page.reload();
  await expect(page.getByLabel('Pending recovery drafts')).toBeVisible();
  await expect(page.getByLabel('Project name', { exact: true })).toHaveValue(p.projectName);
  // Keep writes offline through the lifecycle flush; only reconnect after the
  // journal has demonstrably recovered on a fresh page.
  await page.unroute(endpoint);
  const response = page.waitForResponse((r) => r.url().endsWith('/recover-copy'));
  await page.getByRole('button', { name: 'Recover draft as a copy', exact: true }).click();
  const copy = await (await response).json();
  expect(copy.projectName).toContain('NEVER_IN_DIAGNOSTICS');
  await expect(page.getByLabel('Project name', { exact: true })).toHaveValue(copy.projectName);
  await page.evaluate((id) => localStorage.setItem(`bjj:recovery:${id}:corrupt`, '{broken'), copy.projectId);
  await page.reload();
  await expect(page.getByRole('alert')).toContainText('recovery draft is damaged');
  await expect(page.getByLabel('Project name', { exact: true })).toHaveValue(copy.projectName);
});
