import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const apiPort = process.env.BJJ_E2E_API_PORT ?? '8010';
const webPort = process.env.BJJ_E2E_WEB_PORT ?? '5174';

export default defineConfig({
  testDir: '../tests/browser',
  globalSetup: '../tests/browser/global-setup.ts',
  outputDir: '../tests/generated/playwright-results',
  timeout: 180_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [
    ['list'],
    ['html', { outputFolder: '../tests/generated/playwright-report', open: 'never' }],
  ],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: `http://127.0.0.1:${webPort}`,
    viewport: { width: 1440, height: 960 },
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    acceptDownloads: true,
    launchOptions: {
      executablePath: process.env.BJJ_E2E_CHROMIUM_PATH,
      args: [
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--use-fake-device-for-media-stream',
        '--use-fake-ui-for-media-stream',
        `--use-file-for-fake-audio-capture=${path.join(root, 'tests/generated/microphone-880hz.wav')}`,
      ],
    },
  },
  webServer: [
    {
      command: 'node tests/start-backend.mjs',
      cwd: root,
      url: `http://127.0.0.1:${apiPort}/api/health`,
      env: {
        BJJ_DATA_DIR: path.join(root, 'tests/generated/e2e-data'),
        BJJ_ALLOWED_ORIGINS: `http://127.0.0.1:${webPort}`,
      },
      reuseExistingServer: false,
      timeout: 60_000,
    },
    {
      command: `npm run dev -- --host 127.0.0.1 --port ${webPort} --strictPort`,
      cwd: path.join(root, 'frontend'),
      url: `http://127.0.0.1:${webPort}`,
      env: { BJJ_API_URL: `http://127.0.0.1:${apiPort}` },
      reuseExistingServer: false,
      timeout: 60_000,
    },
  ],
});
