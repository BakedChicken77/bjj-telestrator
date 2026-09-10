import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AudioPreview } from './useAudioPreview';
import { fixture } from './testFixtures';
import { useEditor } from './store';

const node = () => ({ connect: vi.fn(), disconnect: vi.fn() });
const sourceNode = () => ({
  ...node(),
  buffer: null,
  playbackRate: { value: 1 },
  start: vi.fn(),
  stop: vi.fn(),
  onended: null,
});
const gainNode = () => ({ ...node(), gain: { value: 1, setTargetAtTime: vi.fn() } });

class Context {
  static instances: Context[] = [];
  state = 'suspended';
  currentTime = 100;
  destination = node();
  original = node();
  sources: ReturnType<typeof sourceNode>[] = [];
  gains: ReturnType<typeof gainNode>[] = [];
  createMediaElementSource = vi.fn(() => this.original);
  createGain = vi.fn(() => {
    const gain = gainNode();
    this.gains.push(gain);
    return gain;
  });
  createBufferSource = vi.fn(() => {
    const source = sourceNode();
    this.sources.push(source);
    return source;
  });
  decodeAudioData = vi.fn(async () => ({ duration: 4 }));
  resume = vi.fn(async () => {
    this.state = 'running';
  });
  close = vi.fn(async () => {
    this.state = 'closed';
  });
  constructor() {
    Context.instances.push(this);
  }
}

class Video extends EventTarget {
  volume = 1;
  muted = false;
  currentTime = 5;
  playbackRate = 1;
  paused = true;
  ended = false;
  seeking = false;
  readyState = 4;
}

function configuration() {
  const project = fixture();
  project.voiceovers = [
    {
      id: '33333333-3333-4333-8333-333333333333',
      asset: 'voiceover/clip.wav',
      startSec: 5,
      durationSec: 4,
      endSec: 9,
      gain: 0.5,
      muted: false,
      timingOffsetMs: 0,
      recordedAt: '2026-09-05T12:00:00.000Z',
      codec: 'pcm_s16le',
      sampleRate: 48000,
      channels: 1,
    },
  ];
  return { project, monitorVolume: 0.8, recording: false };
}

describe('audio preview lifecycle', () => {
  const controllers: AudioPreview[] = [];
  let gestures: EventTarget;
  beforeEach(() => {
    vi.useFakeTimers();
    Context.instances = [];
    gestures = new EventTarget();
    vi.stubGlobal('window', gestures);
    vi.stubGlobal('AudioContext', Context);
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) })),
    );
    useEditor.getState().setError(null);
  });
  afterEach(async () => {
    controllers.forEach((controller) => controller.dispose());
    controllers.length = 0;
    await vi.runOnlyPendingTimersAsync();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  function open(video = new Video()) {
    const loading = vi.fn();
    const settings = configuration();
    const engine = new AudioPreview(video as unknown as HTMLVideoElement, settings, loading);
    controllers.push(engine);
    return { video, engine, context: Context.instances.at(-1)!, settings, loading };
  }

  async function play(video: Video) {
    gestures.dispatchEvent(new Event('pointerdown'));
    await vi.advanceTimersByTimeAsync(1);
    video.paused = false;
    video.dispatchEvent(new Event('play'));
    video.dispatchEvent(new Event('playing'));
  }

  it('preloads narration, unlocks on a gesture, and stops during buffering and at video end', async () => {
    const { video, context, loading } = open();
    await vi.advanceTimersByTimeAsync(1);
    expect(context.decodeAudioData).toHaveBeenCalledOnce();
    expect(loading).toHaveBeenLastCalledWith(false);
    expect(context.sources).toHaveLength(0);
    await play(video);
    expect(context.sources[0].start).toHaveBeenCalledWith(100, 0, 4);
    video.dispatchEvent(new Event('waiting'));
    expect(context.sources[0].stop).toHaveBeenCalledOnce();
    video.currentTime = 5.4;
    video.dispatchEvent(new Event('canplay'));
    expect(context.sources[1].start).toHaveBeenCalledWith(
      100,
      expect.closeTo(0.4),
      expect.closeTo(3.6),
    );
    video.ended = true;
    video.dispatchEvent(new Event('ended'));
    expect(context.sources[1].stop).toHaveBeenCalledOnce();
  });

  it('updates original gain and mute without disturbing decoded asset cache', async () => {
    const { video, engine, context, settings } = open();
    await play(video);
    settings.project.settings.originalAudioGain = 0.5;
    engine.configure(settings);
    expect(context.gains[0].gain.setTargetAtTime).toHaveBeenLastCalledWith(0.4, 100, 0.01);
    settings.project.settings.originalAudioMuted = true;
    settings.project.voiceovers[0].muted = true;
    engine.configure(settings);
    expect(context.gains[0].gain.setTargetAtTime).toHaveBeenLastCalledWith(0, 100, 0.01);
    expect(context.sources[0].stop).toHaveBeenCalledOnce();
    expect(context.decodeAudioData).toHaveBeenCalledOnce();
  });

  it('reuses an audio source on immediate effect reattachment, then releases an old project element', async () => {
    const first = open();
    first.engine.dispose();
    const reattached = open(first.video);
    expect(Context.instances).toHaveLength(1);
    expect(first.context.createMediaElementSource).toHaveBeenCalledOnce();
    await vi.advanceTimersByTimeAsync(1);
    expect(first.context.close).not.toHaveBeenCalled();
    reattached.engine.dispose();
    const next = open(new Video());
    await vi.advanceTimersByTimeAsync(1);
    expect(Context.instances).toHaveLength(2);
    expect(first.context.close).toHaveBeenCalledOnce();
    expect(first.context.original.disconnect).toHaveBeenCalledOnce();
    expect(next.context.close).not.toHaveBeenCalled();
  });

  it('reports asynchronous decode errors while retaining the original-audio route', async () => {
    const { context, video, loading } = open();
    context.decodeAudioData.mockRejectedValue(new Error('Damaged clip'));
    await vi.advanceTimersByTimeAsync(1);
    expect(useEditor.getState().error).toContain('voiceover could not be prepared');
    expect(loading).toHaveBeenLastCalledWith(false);
    expect(context.original.connect).toHaveBeenCalledOnce();
    expect(context.original.disconnect).not.toHaveBeenCalled();
    video.paused = false;
    video.dispatchEvent(new Event('playing'));
    expect(context.gains[0].gain.setTargetAtTime).toHaveBeenLastCalledWith(0.8, 100, 0.01);
  });
});
