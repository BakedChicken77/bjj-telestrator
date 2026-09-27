import { type Page } from '../../frontend/node_modules/@playwright/test/index.js';

// The 1.1.1 phone header keeps project actions behind its accessible menu button.
export async function clickProjectAction(page: Page, name: 'Projects' | 'Export video') {
  const action = page.getByRole('button', { name, exact: true });
  if (!(await action.isVisible())) {
    await page.getByRole('button', { name: 'Project actions', exact: true }).click();
  }
  await action.click();
}
