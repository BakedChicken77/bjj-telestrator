import { afterEach, describe, expect, it, vi } from 'vitest';
import { loadPCMWindow, parseWAVHeader, PCM_PREVIEW_BUDGET, previewWindows } from './pcmPreview';
import type { Voiceover } from './model';

const clip = (id: string, overrides: Partial<Voiceover> = {}): Voiceover => ({
  id,
  asset: `voiceover/${id}.wav`,
  startSec: 0,
  endSec: 1200,
  durationSec: 1200,
  gain: 1,
  muted: false,
  timingOffsetMs: 0,
  channels: 1,
  sampleRate: 48000,
  codec: 'pcm_s16le',
  recordedAt: '2026-09-13T00:00:00Z',
  ...overrides,
});
afterEach(() => vi.unstubAllGlobals());
describe('bounded PCM preview windows', () => {
  it('retains every active long take while bounding duration after seeks and loop wraps', () => {
    const clips = [clip('a'), clip('b'), clip('c')];
    const windows = previewWindows(clips, 600);
    const active = windows.filter(
      (item) => item.placed.startSec <= 600 && 600 < item.placed.endSec,
    );
    expect(active.map((item) => item.original.id).sort()).toEqual(['a', 'b', 'c']);
    expect(active.map((item) => item.firstSample)).toEqual([28800000, 28800000, 28800000]);
    expect(windows.reduce((sum, item) => sum + item.samples * 4, 0)).toBe(11520000);
    expect(windows.reduce((sum, item) => sum + item.samples * 4, 0)).toBeLessThan(
      PCM_PREVIEW_BUDGET,
    );
    expect(previewWindows(clips, 0).every((item) => item.firstSample < 720001)).toBe(true);
    expect(previewWindows(clips, 1199).every((item) => item.placed.endSec <= 1200)).toBe(true);
    expect(clips.every((item) => item.durationSec === 1200)).toBe(true);
  });
  it('preserves source offsets and excludes muted takes without changing placement', () => {
    const shifted = clip('shift', { startSec: 5, endSec: 1205, timingOffsetMs: -500 });
    const windows = previewWindows([shifted, clip('muted', { muted: true })], 9.5);
    const active = windows.find((item) => item.firstSample === 240000)!;
    expect(active.placed.startSec).toBe(10);
    expect(active.placed.timingOffsetMs).toBe(-500);
    expect(windows.every((item) => item.original.id === 'shift')).toBe(true);
  });
  it('reads exact interleaved samples through scoped byte ranges, without full decoding', async () => {
    const raw = new Uint8Array(44 + 16),
      view = new DataView(raw.buffer);
    const text = (at: number, value: string) =>
      [...value].forEach((character, index) => {
        raw[at + index] = character.charCodeAt(0);
      });
    text(0, 'RIFF');
    view.setUint32(4, raw.length - 8, true);
    text(8, 'WAVE');
    text(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 2, true);
    view.setUint32(24, 8, true);
    view.setUint16(32, 4, true);
    view.setUint16(34, 16, true);
    text(36, 'data');
    view.setUint32(40, 16, true);
    [0, 32767, 16384, -16384, -32768, 8192, 4096, -4096].forEach((sample, i) =>
      view.setInt16(44 + i * 2, sample, true),
    );
    const header = parseWAVHeader(raw.subarray(0, 44));
    expect(header).toEqual({
      channels: 2,
      sampleRate: 8,
      blockAlign: 4,
      dataOffset: 44,
      frames: 4,
    });
    const request = vi.fn(async (_url, options) => {
      expect(options.headers.Range).toBe('bytes=48-55');
      return new Response(raw.slice(48, 56), {
        status: 206,
        headers: { 'Content-Range': 'bytes 48-55/60' },
      });
    });
    vi.stubGlobal('fetch', request);
    const channels: Float32Array[] = [];
    const context = {
      createBuffer: (count: number, length: number) => {
        for (let i = 0; i < count; i++) channels.push(new Float32Array(length));
        return { getChannelData: (index: number) => channels[index] } as AudioBuffer;
      },
    };
    const original = clip('tone', { durationSec: 0.5, endSec: 0.5, channels: 2, sampleRate: 8 });
    await loadPCMWindow(
      context,
      'asset-scoped-test-url',
      { key: 'tone:1', original, placed: original, firstSample: 1, samples: 2 },
      header,
      new AbortController().signal,
    );
    expect([...channels[0]]).toEqual([0.5, -1]);
    expect([...channels[1]]).toEqual([-0.5, 0.25]);
    expect(request).toHaveBeenCalledTimes(1);
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(raw, { status: 200 })),
    );
    await expect(
      loadPCMWindow(
        context,
        'asset-scoped-test-url',
        { key: 'tone:1', original, placed: original, firstSample: 1, samples: 2 },
        header,
        new AbortController().signal,
      ),
    ).rejects.toThrow('Bounded audio access');
    view.setUint16(34, 32, true);
    expect(() => parseWAVHeader(raw)).toThrow('16-bit PCM');
  });
});
