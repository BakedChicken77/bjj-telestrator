// Run: node --expose-gc scripts/profile_editor.mjs [report.json]
// Uses the repository's pinned Vite transform; no new build/runtime dependency.
import { createServer } from '../frontend/node_modules/vite/dist/node/index.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vite = await createServer({ root: path.join(root, 'frontend'), configFile: false, cacheDir: path.join(root, '.ci-artifacts/profile-vite-cache'),
  server: { middlewareMode: true, hmr: false }, appType: 'custom' });
try {
  const { useEditor } = await vite.ssrLoadModule('/src/store.ts');
  const { createAnnotation, visibleAt } = await vite.ssrLoadModule('/src/canvas.ts');
  const { previewWorkingSet } = await vite.ssrLoadModule('/src/audioPreview.ts');
  const { previewWindows } = fs.existsSync(path.join(root, 'frontend/src/pcmPreview.ts'))
    ? await vite.ssrLoadModule('/src/pcmPreview.ts') : {};
  const project = JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/project-conformance.json'), 'utf8')).migrationExpected;
  project.source.durationSec = project.proxy.durationSec = 1200;
  project.voiceovers = [];
  project.annotations = Array.from({ length: 100 }, (_, i) => createAnnotation(i < 20 ? 'freehand' : 'arrow',
    { x: .1, y: .1 }, { x: .7, y: .7 }, i * 5, 1200, 120, i,
    i < 20 ? Array.from({ length: 2000 }, (_, j) => ({ x: .1 + j / 4000, y: .5 + Math.sin(j / 20) * .2 })) : []));
  global.gc?.(); const before = process.memoryUsage();
  useEditor.getState().setProject(project);
  const durations = [];
  for (let i = 0; i < 100; i++) {
    const start = performance.now();
    useEditor.getState().edit((draft) => { draft.annotations[99].endSec = 616 + i / 100; });
    durations.push(performance.now() - start);
  }
  global.gc?.(); const after = process.memoryUsage();
  const state = useEditor.getState();
  const arrays = new Set(state.past.flatMap((p) => p.annotations.filter((a) => a.type === 'freehand').map((a) => a.geometry.points)));
  const start = performance.now(); let visible = 0;
  for (let i = 0; i < 36000; i++) visible += state.project.annotations.filter((item) => visibleAt(item, i / 30)).sort((a, b) => a.zIndex - b.zIndex).length;
  const filtering = performance.now() - start;
  const clips = Array.from({ length: 3 }, (_, i) => ({ id: String(i), asset: `voiceover/${i}.wav`, startSec: 0,
    endSec: 1200, durationSec: 1200, timingOffsetMs: 0, gain: 1, muted: false, sampleRate: 48000, channels: 1 }));
  const working = previewWorkingSet(clips, 600);
  durations.sort((a, b) => a - b);
  const result = { date: new Date().toISOString(), node: process.version, platform: `${os.platform()} ${os.release()} ${os.arch()}`,
    cpu: os.cpus()[0]?.model, logicalCpus: os.cpus().length, workload: { sourceSeconds: 1200, annotations: 100, freehandPaths: 20, pointsPerPath: 2000, historyEdits: 100 },
    editMedianMs: durations[49], editP95Ms: durations[94], editMaxMs: durations[99], heapGrowthBytes: after.heapUsed - before.heapUsed,
    rssBytes: after.rss, historyItems: state.past.length, distinctRetainedFreehandArrays: arrays.size,
    filteringFrames: 36000, filteringTotalMs: filtering, filteringMsPerFrame: filtering / 36000, visibleCount: visible,
    activeOverlapClips: working.length, fullDecodeAudioBytes: working.reduce((sum, clip) => sum + clip.durationSec * clip.sampleRate * clip.channels * 4, 0),
    windowedAudioBytes: previewWindows ? previewWindows(clips, 600).reduce((sum, item) => sum + item.samples * item.original.channels * 4, 0) : null,
    limitations: 'Node profiling isolates state/filtering; it does not measure browser React commits, physical phone thermals or native export.' };
  const output = JSON.stringify(result, null, 2) + '\n';
  if (process.argv[2]) fs.writeFileSync(process.argv[2], output);
  process.stdout.write(output);
} finally { await vite.close(); }
