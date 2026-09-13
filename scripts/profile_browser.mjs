// Profile the real development editor using profile_phase1.py's generated export-device.
// Usage: BJJ_E2E_CHROMIUM_PATH=... node scripts/profile_browser.mjs DATA_DIR OUTPUT_DIR
// The ten reversible style edits affect the generated review; never use personal media.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { createReadStream, mkdirSync, openSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const require = createRequire(resolve(root, 'frontend/package.json'));
const { chromium } = require('playwright');
const [dataDir, outputDir] = process.argv.slice(2).map((p) => resolve(p));
if (!dataDir || !outputDir) throw new Error('Provide generated DATA_DIR and a new OUTPUT_DIR.');
mkdirSync(outputDir, { recursive: false });
const python = process.env.BJJ_E2E_PYTHON ?? resolve(root,
  process.platform === 'win32' ? 'backend/.venv/Scripts/python.exe' : 'backend/.venv/bin/python');
const backend = spawn(python,
  ['-m', 'uvicorn', 'app.main:app', '--app-dir', 'backend', '--host', '127.0.0.1', '--port', '8012'],
  { cwd: root, env: { ...process.env, BJJ_DATA_DIR: dataDir, BJJ_ALLOWED_ORIGINS: 'http://127.0.0.1:5176' },
    stdio: ['ignore', openSync(resolve(outputDir, 'backend.log'), 'w'), 'ignore'] });
const web = spawn(process.execPath, [resolve(root, 'frontend/node_modules/vite/bin/vite.js'),
  '--host', '127.0.0.1', '--port', '5176', '--strictPort'],
  { cwd: resolve(root, 'frontend'), env: { ...process.env, BJJ_API_URL: 'http://127.0.0.1:8012' },
    stdio: ['ignore', openSync(resolve(outputDir, 'vite.log'), 'w'), 'ignore'] });
let browser;
async function ready(url) {
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(url)).ok) return; } catch { /* Startup only. */ }
    await new Promise((done) => setTimeout(done, 250));
  }
  throw new Error('The profiling server did not start. Inspect bounded local logs.');
}
async function hash(path) {
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(path)) digest.update(chunk);
  return digest.digest('hex');
}
try {
  await Promise.all([ready('http://127.0.0.1:8012/api/health'), ready('http://127.0.0.1:5176')]);
  const projects = await (await fetch('http://127.0.0.1:8012/api/projects')).json();
  if (projects.length !== 1) throw new Error('Use the single generated export-device library.');
  const project = await (await fetch(`http://127.0.0.1:8012/api/projects/${projects[0].projectId}`)).json();
  if (project.annotations.length !== 100 || project.voiceovers.length !== 3 || project.source.durationSec !== 1200)
    throw new Error('Expected the documented synthetic 20-minute scale fixture.');
  const source = resolve(dataDir, 'projects', project.projectId, project.source.asset);
  const sourceSHA256 = await hash(source);
  browser = await chromium.launch({ executablePath: process.env.BJJ_E2E_CHROMIUM_PATH,
    args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  const errors = [], audioRanges = [], audioAssets = new Set();
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('response', (response) => {
    if (/\/voiceovers\/[^/]+\/audio$/.test(new URL(response.url()).pathname)) {
      audioAssets.add(response.url());
      audioRanges.push({ status: response.status(), range: response.request().headers().range,
        bytes: Number(response.headers()['content-length']) });
    }
  });
  await page.addInitScript(() => {
    window.phase1Profile = { commits: 0, longTasks: [], frameIntervals: [], lastFrame: 0 };
    window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      supportsFiber: true, renderers: new Map(), inject: () => 1,
      onCommitFiberRoot: () => { window.phase1Profile.commits++; }, onCommitFiberUnmount: () => {},
    };
    new PerformanceObserver((entries) => {
      for (const entry of entries.getEntries()) window.phase1Profile.longTasks.push(entry.duration);
    }).observe({ type: 'longtask', buffered: true });
    function frame(now) {
      const sample = window.phase1Profile;
      if (sample.lastFrame) sample.frameIntervals.push(now - sample.lastFrame);
      sample.lastFrame = now;
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Performance.enable');
  await page.goto('http://127.0.0.1:5176');
  await page.locator('.project-open').click();
  await page.locator('video').waitFor();
  await page.getByLabel('Annotation selection', { exact: true }).selectOption(project.annotations[0].id);
  const samples = [];
  for (let i = 0; i < 10; i++) {
    const before = await page.evaluate(() => ({ time: performance.now(), commits: window.phase1Profile.commits }));
    const field = page.getByLabel('Stroke width (px)', { exact: true });
    await field.fill(String(4 + i % 2));
    await field.press('Tab');
    const after = await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() =>
      done({ time: performance.now(), commits: window.phase1Profile.commits })))));
    samples.push({ elapsedToPaintMs: after.time - before.time, reactCommits: after.commits - before.commits });
  }
  const edits = await page.evaluate(() => structuredClone(window.phase1Profile));
  await page.getByTestId('save-status').filter({ hasText: /^Saved$/ }).waitFor();
  await page.screenshot({ path: resolve(outputDir, 'editor.png'), fullPage: true });
  await page.evaluate(() => { window.phase1Profile.commits = 0; window.phase1Profile.longTasks = []; window.phase1Profile.frameIntervals = []; });
  await page.getByRole('button', { name: 'Play video', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('video').currentTime >= 12, undefined, { timeout: 30000 });
  await page.getByRole('button', { name: 'Pause video', exact: true }).click();
  const playback = await page.evaluate(() => ({ ...window.phase1Profile, resolvedTime: document.querySelector('video').currentTime }));
  await cdp.send('HeapProfiler.collectGarbage');
  const metrics = (await cdp.send('Performance.getMetrics')).metrics.filter(({ name }) =>
    ['JSHeapUsedSize', 'JSHeapTotalSize', 'Nodes', 'LayoutCount', 'RecalcStyleCount'].includes(name));
  if (sourceSHA256 !== await hash(source)) throw new Error('The source changed.');
  if (audioAssets.size !== 3 || audioRanges.some((range) => range.status !== 206
    || !Number.isFinite(range.bytes) || range.bytes <= 0 || range.bytes > 2 * 1024**2
    || !/^bytes=\d+-\d+$/.test(range.range ?? '')))
    throw new Error('Narration was not delivered through bounded byte ranges.');
  if (!edits.commits || errors.length) throw new Error('Missing React evidence or browser runtime error.');
  const compact = ({ commits, longTasks, frameIntervals, resolvedTime }) => ({ commits, longTaskCount: longTasks.length,
    longestTaskMs: Math.max(0, ...longTasks), maxAnimationFrameIntervalMs: Math.max(0, ...frameIntervals), resolvedTime });
  writeFileSync(resolve(outputDir, 'report.json'), JSON.stringify({ browser: browser.version(), viewport: [1280, 720],
    sourceSHA256, annotations: 100, narrationTracks: 3, sourceSeconds: 1200, editSamples: samples,
    edits: compact(edits), playback: compact(playback), metrics, audioRanges,
    limitations: 'Headless Linux development build including StrictMode and automation overhead. Twelve seconds of preview; no hardware synchronization, listening or thermal acceptance. React counts are commits, not render duration.' }, null, 2) + '\n');
  console.log('Real editor profile recorded. Source unchanged; all three narration assets used bounded ranges.');
} finally {
  await browser?.close(); backend.kill('SIGTERM'); web.kill('SIGTERM');
}
