import { describe, expect, it } from 'vitest';
import { formatTime, parseTime, rulerStep, shiftInterval, trimInterval } from './timelineMath';

describe('timeline edits', () => {
  it('shifts intervals preserving duration at both video boundaries', () => {
    expect(shiftInterval({ startSec: 5, endSec: 10 }, -8, 20)).toEqual({ startSec: 0, endSec: 5 });
    expect(shiftInterval({ startSec: 5, endSec: 10 }, 18, 20)).toEqual({
      startSec: 15,
      endSec: 20,
    });
    expect(shiftInterval({ startSec: 5, endSec: 10 }, 2.25, 20)).toEqual({
      startSec: 7.25,
      endSec: 12.25,
    });
  });

  it('trims either edge without crossing the opposite edge', () => {
    expect(trimInterval({ startSec: 5, endSec: 10 }, 'start', -1, 20)).toEqual({
      startSec: 0,
      endSec: 10,
    });
    expect(trimInterval({ startSec: 5, endSec: 10 }, 'end', 100, 20)).toEqual({
      startSec: 5,
      endSec: 20,
    });
    expect(trimInterval({ startSec: 5, endSec: 10 }, 'start', 12, 20).startSec).toBeCloseTo(9.999);
    expect(trimInterval({ startSec: 5, endSec: 10 }, 'end', 1, 20).endSec).toBeCloseTo(5.001);
  });

  it('preserves a valid interval on a submillisecond source', () => {
    expect(trimInterval({ startSec: 0, endSec: 0.0005 }, 'start', 1, 0.0005)).toEqual({
      startSec: 0,
      endSec: 0.0005,
    });
    expect(trimInterval({ startSec: 0, endSec: 0.0005 }, 'start', 1, 20)).toEqual({
      startSec: 0,
      endSec: 0.0005,
    });
    expect(trimInterval({ startSec: 19.9995, endSec: 20 }, 'end', 0, 20)).toEqual({
      startSec: 19.9995,
      endSec: 20,
    });
  });
});

describe('human-readable media time', () => {
  it('formats milliseconds, hour boundaries and rounding carry correctly', () => {
    expect(formatTime(84.25)).toBe('01:24.250');
    expect(formatTime(59.9999)).toBe('01:00.000');
    expect(formatTime(3601.002)).toBe('01:00:01.002');
    expect(formatTime(-1)).toBe('00:00.000');
  });

  it('accepts seconds and readable timestamps', () => {
    expect(parseTime('84.250')).toBe(84.25);
    expect(parseTime('01:24.250')).toBe(84.25);
    expect(parseTime('01:00:01.002')).toBe(3601.002);
    expect(parseTime('120:00')).toBe(7200);
  });

  it('rejects malformed or nonfinite input', () => {
    for (const input of [
      '',
      'abc',
      '-1',
      '1:60',
      '1:61:00',
      '1.2.3',
      'Infinity',
      '1:2:3:4',
      '0.1234',
    ]) {
      expect(parseTime(input)).toBeNull();
    }
  });

  it('keeps ruler labels separated as the view zooms', () => {
    expect(rulerStep(100)).toBe(1);
    expect(rulerStep(5)).toBe(15);
    expect(rulerStep(0.5)).toBe(300);
  });
});
