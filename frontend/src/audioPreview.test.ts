import { describe, expect, it, vi } from 'vitest';
import type { Voiceover } from './model';
import {
  clipPlaybackPlan,
  needsAudioResync,
  previewGains,
  previewWorkingSet,
  VoiceoverTransport,
} from './audioPreview';

function clip(overrides: Partial<Voiceover> = {}): Voiceover {
  return {
    id: 'a31de4ae-8975-4601-89d7-65cbdc1d825d',
    asset: 'voiceover/clip.wav',
    startSec: 5,
    durationSec: 4,
    endSec: 9,
    gain: 1,
    muted: false,
    timingOffsetMs: 0,
    recordedAt: '2026-09-05T12:00:00.000Z',
    codec: 'pcm_s16le',
    sampleRate: 48000,
    channels: 1,
    ...overrides,
  };
}

function audioContext() {
  const sourceFactory = () => ({
    buffer: null,
    playbackRate: { value: 1 },
    connect: vi.fn(),
    disconnect: vi.fn(),
    start: vi.fn(),
    stop: vi.fn(),
    onended: null,
  });
  const gainFactory = () => ({
    gain: { value: 1, setTargetAtTime: vi.fn() },
    connect: vi.fn(),
    disconnect: vi.fn(),
  });
  const sources: ReturnType<typeof sourceFactory>[] = [];
  const gains: ReturnType<typeof gainFactory>[] = [];
  function createSource() {
    const source = sourceFactory();
    sources.push(source);
    return source;
  }
  function createGain() {
    const gain = gainFactory();
    gains.push(gain);
    return gain;
  }
  const context = {
    currentTime: 100,
    state: 'running',
    createBufferSource: createSource,
    createGain,
  };
  const transport = new VoiceoverTransport(context as unknown as AudioContext, {} as AudioNode);
  return { context, sources, gains, transport };
}

const buffersFor = (...clips: Voiceover[]): Map<string, AudioBuffer> =>
  new Map(clips.map((item) => [item.id, { duration: item.durationSec } as AudioBuffer]));

describe('voiceover media-time scheduling', () => {
  it('schedules later-decoded adjacent windows from the original anchor without a seam', () => {
    const first = clip({ id: 'first', startSec: 5, durationSec: 5, endSec: 10 });
    const second = clip({ id: 'second', startSec: 10, durationSec: 5, endSec: 15 });
    const { context, sources, transport } = audioContext();
    transport.sync(5, 1, [first, second], buffersFor(first), true);
    context.currentTime = 103;
    transport.sync(8.02, 1, [first, second], buffersFor(first, second), true);
    expect(sources[1].start).toHaveBeenCalledWith(105, 0, 5);
    context.currentTime = 104.98;
    transport.sync(10.01, 1, [first, second], buffersFor(first, second), true);
    expect(sources[0].stop).not.toHaveBeenCalled();
    context.currentTime = 105.02;
    transport.sync(10.02, 1, [first, second], buffersFor(first, second), true);
    expect(sources[0].stop).toHaveBeenCalledOnce();
  });
  it('keeps only clips in the lookbehind/lookahead window and replaces them after a long seek', () => {
    const clips = Array.from({ length: 200 }, (_, index) =>
      clip({ id: String(index), startSec: index * 10, endSec: index * 10 + 4 }),
    );
    expect(previewWorkingSet(clips, 5).map((item) => item.id)).toEqual(['1', '2', '3', '0']);
    expect(previewWorkingSet(clips, 105).map((item) => item.id)).toEqual(['11', '12', '13', '10']);
  });

  it('caps background decode estimates while retaining active overlapping narration', () => {
    const a = clip({ id: 'a', durationSec: 10, endSec: 15 });
    const b = clip({ id: 'b', startSec: 7, durationSec: 10, endSec: 17 });
    const c = clip({ id: 'c', startSec: 10, durationSec: 10, endSec: 20 });
    const tenSeconds = 10 * 48000 * 4;
    expect(previewWorkingSet([a, b, c], 4, tenSeconds).map((item) => item.id)).toEqual(['a']);
    expect(previewWorkingSet([a, b, c], 8, tenSeconds).map((item) => item.id)).toEqual(['b', 'a']);
  });
  it('schedules a future clip using the shared audio clock', () => {
    expect(clipPlaybackPlan(clip(), 3, 100, 4)).toEqual({
      when: 102,
      offsetSec: 0,
      durationSec: 4,
      effectiveStartSec: 5,
    });
  });

  it('seeks into a clip using the correct decoded-audio offset', () => {
    expect(clipPlaybackPlan(clip(), 6.25, 100, 4)).toEqual({
      when: 100,
      offsetSec: 1.25,
      durationSec: 2.75,
      effectiveStartSec: 5,
    });
  });

  it('applies timing nudges and playback rate without changing source-second offsets', () => {
    expect(clipPlaybackPlan(clip({ timingOffsetMs: -500 }), 3.5, 100, 4, 2)?.when).toBe(100.5);
    expect(clipPlaybackPlan(clip({ timingOffsetMs: 200 }), 6.2, 100, 4, 2)?.offsetSec).toBeCloseTo(
      1,
    );
  });

  it('uses half-open intervals, muted state, and actual buffer duration', () => {
    expect(clipPlaybackPlan(clip(), 9, 100, 4)).toBeNull();
    expect(clipPlaybackPlan(clip({ muted: true }), 6, 100, 4)).toBeNull();
    expect(clipPlaybackPlan(clip(), 7, 100, 2)).toBeNull();
    expect(clipPlaybackPlan(clip(), 6, 100, 2)?.durationSec).toBe(1);
  });

  it('resynchronizes above 50ms drift or a playback-rate change', () => {
    const anchor = { mediaTime: 5, contextTime: 100, playbackRate: 1 };
    expect(needsAudioResync(anchor, 5.06, 100.1, 1)).toBe(false);
    expect(needsAudioResync(anchor, 5, 100.1, 1)).toBe(true);
    expect(needsAudioResync(anchor, 5.1, 100.1, 2)).toBe(true);
  });

  it('applies original and voiceover controls independently with a monitor master', () => {
    expect(previewGains(0.5, false, 1.5, 0.8, false)).toEqual({
      original: 0.4,
      voiceover: 1.2000000000000002,
    });
    expect(previewGains(2, true, 3, 1, true)).toEqual({ original: 0, voiceover: 0 });
  });
});

describe('Web Audio transport behavior', () => {
  it('starts overlapping buffers at their own offsets and clips gain', () => {
    const first = clip({ gain: 0.4 });
    const second = clip({ id: 'second', startSec: 6, endSec: 10, gain: 1.5 });
    const { transport, sources, gains } = audioContext();
    transport.sync(6.5, 1, [first, second], buffersFor(first, second), true);
    expect(sources[0].start).toHaveBeenCalledWith(100, 1.5, 2.5);
    expect(sources[1].start).toHaveBeenCalledWith(100, 0.5, 3.5);
    expect(gains.map((gain) => gain.gain.value)).toEqual([0.4, 1.5]);
  });

  it('keeps healthy sources running across polling ticks', () => {
    const voice = clip();
    const { transport, sources, context } = audioContext();
    transport.sync(5, 1, [voice], buffersFor(voice), true);
    context.currentTime += 0.04;
    transport.sync(5.04, 1, [voice], buffersFor(voice), true);
    expect(sources).toHaveLength(1);
    expect(sources[0].stop).not.toHaveBeenCalled();
  });

  it('stops old buffers and replaces them at a new offset after a seek', () => {
    const voice = clip();
    const { transport, sources } = audioContext();
    transport.sync(5, 1, [voice], buffersFor(voice), true);
    transport.sync(7, 1, [voice], buffersFor(voice), true);
    expect(sources[0].stop).toHaveBeenCalledOnce();
    expect(sources[0].disconnect).toHaveBeenCalledOnce();
    expect(sources[1].start).toHaveBeenCalledWith(100, 2, 2);
  });

  it('stops narration immediately on pause or active recording and resumes at media time', () => {
    const voice = clip();
    const { transport, sources } = audioContext();
    transport.sync(5, 1, [voice], buffersFor(voice), true);
    transport.sync(5.5, 1, [voice], buffersFor(voice), false);
    expect(sources[0].stop).toHaveBeenCalledOnce();
    transport.sync(6, 1, [voice], buffersFor(voice), true);
    expect(sources[1].start).toHaveBeenCalledWith(100, 1, 3);
  });

  it('schedules upcoming clips only within the lookahead and prevents muted playback', () => {
    const voice = clip();
    const { transport, sources } = audioContext();
    transport.sync(1, 1, [voice], buffersFor(voice), true);
    expect(sources).toHaveLength(0);
    transport.sync(3, 1, [voice], buffersFor(voice), true);
    expect(sources[0].start).toHaveBeenCalledWith(102, 0, 4);
    transport.sync(3, 1, [{ ...voice, muted: true }], buffersFor(voice), true);
    expect(sources[0].stop).toHaveBeenCalledOnce();
    expect(sources).toHaveLength(1);
  });

  it('waits for a running audio context and disconnects everything at stop', () => {
    const voice = clip();
    const { transport, sources, gains, context } = audioContext();
    context.state = 'suspended';
    transport.sync(5, 1, [voice], buffersFor(voice), true);
    expect(sources).toHaveLength(0);
    context.state = 'running';
    transport.sync(5, 1, [voice], buffersFor(voice), true);
    transport.stop();
    expect(sources[0].disconnect).toHaveBeenCalledOnce();
    expect(gains[0].disconnect).toHaveBeenCalledOnce();
  });
});
