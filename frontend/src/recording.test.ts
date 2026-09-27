import { describe, expect, it } from 'vitest';
import {
  chooseRecordingFormat,
  clampVoiceoverOffset,
  clampVoiceoverStart,
  recordingStart,
} from './recording';

describe('linear voiceover mapping', () => {
  it('starts at absolute media time and rejects end-of-video recordings', () => {
    expect(recordingStart(8.125, 20)).toBe(8.125);
    expect(() => recordingStart(20, 20)).toThrow(/Seek/);
    expect(() => recordingStart(Number.NaN, 20)).toThrow();
  });
  it('selects supported formats without assuming all browsers support Opus', () => {
    expect(chooseRecordingFormat((type) => type.includes('webm'))).toEqual({
      mimeType: 'audio/webm;codecs=opus',
      extension: 'webm',
    });
    expect(chooseRecordingFormat((type) => type === 'audio/mp4')).toEqual({
      mimeType: 'audio/mp4',
      extension: 'm4a',
    });
    expect(chooseRecordingFormat(() => false)).toBeNull();
  });
  it('keeps moved and nudged clips on the source timeline', () => {
    expect(clampVoiceoverStart(18, 3, 500, 20)).toBe(16.5);
    expect(clampVoiceoverStart(0, 3, -500, 20)).toBe(0.5);
    expect(clampVoiceoverOffset(-1000, 0.3, 3, 20)).toBe(-300);
    expect(clampVoiceoverOffset(500, 18, 2, 20)).toBe(0);
  });
});
