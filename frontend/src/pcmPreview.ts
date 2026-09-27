import type { Voiceover } from './model';
import { previewWorkingSet } from './audioPreview';

export const PCM_WINDOW_SECONDS = 5;
export const PCM_PREVIEW_BUDGET = 64 * 1024 * 1024;
export interface PCMWindow {
  key: string;
  original: Voiceover;
  placed: Voiceover;
  firstSample: number;
  samples: number;
}
export interface WAVHeader {
  channels: number;
  sampleRate: number;
  blockAlign: number;
  dataOffset: number;
  frames: number;
}

/** Runtime fragments only. Immutable recording files and persisted clip IDs stay unchanged. */
export function previewWindows(clips: readonly Voiceover[], mediaTime: number): PCMWindow[] {
  const result: PCMWindow[] = [];
  for (const original of previewWorkingSet(clips, mediaTime, Infinity)) {
    if (original.muted || original.gain === 0) continue;
    const start = original.startSec + original.timingOffsetMs / 1000;
    const first = Math.max(0, Math.floor((mediaTime - start - 1) / PCM_WINDOW_SECONDS));
    const last = Math.min(
      Math.ceil(original.durationSec / PCM_WINDOW_SECONDS) - 1,
      Math.floor((mediaTime - start + 10) / PCM_WINDOW_SECONDS),
    );
    for (let index = first; index <= last; index++) {
      const firstSample = Math.round(index * PCM_WINDOW_SECONDS * original.sampleRate);
      const samples = Math.min(
        Math.round(PCM_WINDOW_SECONDS * original.sampleRate),
        Math.round(original.durationSec * original.sampleRate) - firstSample,
      );
      if (samples <= 0) continue;
      const key = `${original.id}:${firstSample}`;
      const startSec = original.startSec + firstSample / original.sampleRate;
      result.push({
        key,
        original,
        firstSample,
        samples,
        placed: {
          ...original,
          id: key,
          startSec,
          durationSec: samples / original.sampleRate,
          endSec: startSec + samples / original.sampleRate,
        },
      });
    }
  }
  return result.sort((a, b) => {
    const distance = (item: PCMWindow) => {
      const start = item.placed.startSec + item.placed.timingOffsetMs / 1000;
      return start <= mediaTime && mediaTime < start + item.placed.durationSec
        ? -1
        : Math.abs(start - mediaTime);
    };
    return distance(a) - distance(b) || a.key.localeCompare(b.key);
  });
}

/** Never accept a server ignoring Range and buffering an entire long recording. */
async function bytes(
  url: string,
  first: number,
  last: number,
  signal: AbortSignal,
): Promise<Uint8Array> {
  const response = await fetch(url, { headers: { Range: `bytes=${first}-${last}` }, signal });
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') ?? '');
  if (
    response.status !== 206 ||
    !range ||
    Number(range[1]) !== first ||
    Number(range[2]) > last ||
    Number(range[2]) < first
  ) {
    await response.body?.cancel();
    throw new Error('Bounded audio access is unavailable. Reopen the project and try again.');
  }
  const expected = Number(range[2]) - first + 1;
  if (expected > 32 * 1024 * 1024) {
    await response.body?.cancel();
    throw new Error('This audio window exceeds preview limits.');
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error('Audio data could not be read.');
  const result = new Uint8Array(expected);
  let count = 0;
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      if (chunk.value.length > expected - count)
        throw new Error('Audio data exceeded the requested window.');
      result.set(chunk.value, count);
      count += chunk.value.length;
    }
  } catch (error) {
    await reader.cancel();
    throw error;
  } finally {
    reader.releaseLock();
  }
  if (count !== expected) throw new Error('The audio window is incomplete.');
  return result;
}

export function parseWAVHeader(raw: Uint8Array): WAVHeader {
  const data = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const text = (at: number, size: number) => String.fromCharCode(...raw.subarray(at, at + size));
  const invalid = () =>
    new Error(
      'This recording is not a supported 16-bit PCM WAV. Restore its original recording asset.',
    );
  if (raw.length < 12 || text(0, 4) !== 'RIFF' || text(8, 4) !== 'WAVE') throw invalid();
  let format: Omit<WAVHeader, 'dataOffset' | 'frames'> | undefined;
  for (let at = 12; at + 8 <= raw.length;) {
    const length = data.getUint32(at + 4, true),
      name = text(at, 4),
      start = at + 8;
    if (name === 'data') {
      if (!format || length % format.blockAlign !== 0) throw invalid();
      return { ...format, dataOffset: start, frames: length / format.blockAlign };
    }
    if (start + length > raw.length) throw invalid();
    if (name === 'fmt ') {
      if (length < 16) throw invalid();
      const encoding = data.getUint16(start, true),
        channels = data.getUint16(start + 2, true);
      const sampleRate = data.getUint32(start + 4, true),
        blockAlign = data.getUint16(start + 12, true);
      const pcm =
        encoding === 1 ||
        (encoding === 0xfffe &&
          length >= 40 &&
          data.getUint16(start + 16, true) >= 22 &&
          text(start + 24, 16) ===
            String.fromCharCode(1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113));
      if (
        !pcm ||
        channels < 1 ||
        channels > 8 ||
        sampleRate < 1 ||
        sampleRate > 384000 ||
        blockAlign !== channels * 2 ||
        data.getUint16(start + 14, true) !== 16
      )
        throw invalid();
      format = { channels, sampleRate, blockAlign };
    }
    at = start + length + (length % 2);
  }
  throw invalid();
}

export async function loadWAVHeader(url: string, signal: AbortSignal): Promise<WAVHeader> {
  return parseWAVHeader(await bytes(url, 0, 65535, signal));
}
export async function loadPCMWindow(
  context: Pick<AudioContext, 'createBuffer'>,
  url: string,
  window: PCMWindow,
  header: WAVHeader,
  signal: AbortSignal,
): Promise<AudioBuffer> {
  if (
    header.channels !== window.original.channels ||
    header.sampleRate !== window.original.sampleRate ||
    Math.abs(header.frames / header.sampleRate - window.original.durationSec) > 0.0011
  )
    throw new Error('The recording no longer matches its saved audio metadata.');
  const samples = Math.min(window.samples, header.frames - window.firstSample);
  if (samples <= 0) throw new Error('The requested audio window is outside the recording.');
  const start = header.dataOffset + window.firstSample * header.blockAlign;
  const raw = await bytes(url, start, start + samples * header.blockAlign - 1, signal);
  if (raw.length !== samples * header.blockAlign) throw new Error('The recording is truncated.');
  const data = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const output = context.createBuffer(header.channels, samples, header.sampleRate);
  for (let channel = 0; channel < header.channels; channel++) {
    const target = output.getChannelData(channel);
    for (let index = 0; index < samples; index++)
      target[index] = data.getInt16((index * header.channels + channel) * 2, true) / 32768;
  }
  return output;
}
