import { beforeEach, afterEach, expect, it, vi } from 'vitest';
import { fixture } from './testFixtures';
import { useEditor } from './store';
const mocks = vi.hoisted(() => ({
  save: vi.fn(),
  prepare: vi.fn(),
  start: vi.fn(),
  stop: vi.fn(),
}));
vi.mock('./project/saveSession', () => ({ flushActiveSave: mocks.save }));
vi.mock('./native', () => ({
  nativeBridge: { prepareRecording: mocks.prepare, startRecording: mocks.start },
  nativeAPI: { stopRecording: mocks.stop },
}));
import { NativeRecordingSession } from './nativeRecordingSession';
class Video extends EventTarget {
  currentTime = 1;
  paused = true;
  ended = false;
  pause = vi.fn(() => {
    this.paused = true;
    this.dispatchEvent(new Event('pause'));
  });
  play = vi.fn(async () => {
    this.paused = false;
  });
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
let video: Video;
let update: ReturnType<typeof vi.fn<(state: string, message: string) => void>>;
let controller: NativeRecordingSession;
const token = () => mocks.prepare.mock.calls.at(-1)![0].sessionId as string;
beforeEach(() => {
  vi.resetAllMocks();
  vi.stubGlobal('document', Object.assign(new EventTarget(), { hidden: false }));
  useEditor.getState().setProject(fixture());
  mocks.save.mockResolvedValue(fixture());
  mocks.prepare.mockResolvedValue(undefined);
  mocks.start.mockResolvedValue({ elapsedSec: 0 });
  mocks.stop.mockResolvedValue(null);
  video = new Video();
  update = vi.fn();
  controller = new NativeRecordingSession(() => video as unknown as HTMLVideoElement, update);
});
afterEach(async () => {
  await controller.stop();
  vi.unstubAllGlobals();
});
it('does not start after an interruption while playback is pending and never falsely says saved', async () => {
  const playback = deferred<void>();
  video.play.mockImplementation(() => playback.promise);
  const starting = controller.start();
  await vi.waitFor(() => expect(video.play).toHaveBeenCalled());
  await controller.finished({
    projectId: fixture().projectId,
    sessionId: token(),
    reason: 'Recording saved after an audio interruption.',
  });
  playback.resolve();
  await starting;
  expect(mocks.start).not.toHaveBeenCalled();
  expect(update).toHaveBeenLastCalledWith(
    'idle',
    expect.stringContaining('before a clip could be saved'),
  );
  expect(useEditor.getState().recording).toBe(false);
});
it('cancels during permission and rejects its delayed continuation', async () => {
  const permission = deferred<void>();
  mocks.prepare.mockReturnValue(permission.promise);
  const starting = controller.start();
  await vi.waitFor(() => expect(mocks.prepare).toHaveBeenCalled());
  await controller.stop();
  permission.resolve();
  await starting;
  expect(video.play).not.toHaveBeenCalled();
  expect(mocks.start).not.toHaveBeenCalled();
  expect(mocks.stop).toHaveBeenCalledWith(token(), undefined);
});
it('ignores stale session events during a later recording', async () => {
  await controller.start();
  const old = token();
  await controller.stop();
  await controller.start();
  const current = token();
  expect(current).not.toBe(old);
  await controller.finished({ projectId: fixture().projectId, sessionId: old, reason: 'stale' });
  expect(useEditor.getState().recording).toBe(true);
  expect(update).toHaveBeenLastCalledWith('recording', '');
});
it('fences delayed native start and collapses duplicate stops', async () => {
  const capture = deferred<{ elapsedSec: number }>();
  mocks.start.mockReturnValue(capture.promise);
  const starting = controller.start();
  await vi.waitFor(() => expect(mocks.start).toHaveBeenCalled());
  await Promise.all([controller.stop(), controller.stop()]);
  capture.resolve({ elapsedSec: 0 });
  await starting;
  expect(mocks.stop).toHaveBeenCalledTimes(1);
  expect(update).toHaveBeenLastCalledWith(
    'idle',
    expect.stringContaining('No recording was saved'),
  );
});
it('recovers from denied permission and playback failure', async () => {
  mocks.prepare.mockRejectedValueOnce(new Error('Microphone access denied'));
  await controller.start();
  expect(useEditor.getState().error).toContain('denied');
  expect(useEditor.getState().recording).toBe(false);
  video.play.mockRejectedValueOnce(new Error('Playback blocked'));
  await controller.start();
  expect(useEditor.getState().error).toBe('Playback blocked');
  expect(mocks.start).not.toHaveBeenCalled();
  expect(useEditor.getState().recording).toBe(false);
});
it('retains one completed clip when stop races the completion event', async () => {
  const clip = {
    id: '33333333-3333-4333-8333-333333333333',
    asset: 'voiceover/clip.wav',
    startSec: 1,
    durationSec: 2,
    endSec: 3,
    gain: 1,
    muted: false,
    timingOffsetMs: 0,
    recordedAt: '2026-09-27T17:00:00.000Z',
    codec: 'pcm_s16le',
    sampleRate: 48000,
    channels: 1,
  };
  mocks.stop.mockResolvedValue(clip);
  await controller.start();
  await Promise.all([
    controller.stop(),
    controller.finished({
      projectId: fixture().projectId,
      sessionId: token(),
      clip,
      reason: 'Recording saved.',
    }),
  ]);
  expect(useEditor.getState().project?.voiceovers).toHaveLength(1);
  expect(mocks.stop).toHaveBeenCalledTimes(1);
  expect(update).toHaveBeenLastCalledWith('idle', 'Recording saved.');
});
it('stops when backgrounded while starting and allows a new attempt', async () => {
  const playback = deferred<void>();
  video.play.mockImplementationOnce(() => playback.promise);
  const starting = controller.start();
  await vi.waitFor(() => expect(video.play).toHaveBeenCalled());
  Object.defineProperty(document, 'hidden', { value: true, configurable: true });
  document.dispatchEvent(new Event('visibilitychange'));
  await vi.waitFor(() => expect(useEditor.getState().recording).toBe(false));
  playback.resolve();
  await starting;
  Object.defineProperty(document, 'hidden', { value: false });
  await controller.start();
  expect(update).toHaveBeenLastCalledWith('recording', '');
});
