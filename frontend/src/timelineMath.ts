/** Timeline values are absolute media seconds, never elapsed wall time. */
export interface TimeInterval {
  startSec: number;
  endSec: number;
}

export const clamp = (value: number, low: number, high: number): number =>
  Math.min(high, Math.max(low, value));

export function shiftInterval(
  interval: TimeInterval,
  deltaSec: number,
  durationSec: number,
): TimeInterval {
  const length = Math.min(durationSec, interval.endSec - interval.startSec);
  const startSec = clamp(interval.startSec + deltaSec, 0, durationSec - length);
  return { startSec, endSec: startSec + length };
}

export function trimInterval(
  interval: TimeInterval,
  edge: 'start' | 'end',
  timeSec: number,
  durationSec: number,
): TimeInterval {
  const minimum = Math.min(
    0.001,
    edge === 'start' ? interval.endSec : durationSec - interval.startSec,
  );
  return edge === 'start'
    ? { startSec: clamp(timeSec, 0, interval.endSec - minimum), endSec: interval.endSec }
    : {
        startSec: interval.startSec,
        endSec: clamp(timeSec, interval.startSec + minimum, durationSec),
      };
}

/** Rounding before splitting avoids values such as 00:59.1000. */
export function formatTime(seconds: number): string {
  const milliseconds = Math.round(Math.max(0, seconds) * 1000);
  const hours = Math.floor(milliseconds / 3_600_000);
  const minutes = Math.floor(milliseconds / 60_000) % 60;
  const wholeSeconds = Math.floor(milliseconds / 1000) % 60;
  const fraction = milliseconds % 1000;
  const body = `${String(minutes).padStart(2, '0')}:${String(wholeSeconds).padStart(2, '0')}.${String(fraction).padStart(3, '0')}`;
  return hours ? `${String(hours).padStart(2, '0')}:${body}` : body;
}

/** Accept seconds, MM:SS.mmm, or HH:MM:SS.mmm. Empty/negative/nonfinite input is invalid. */
export function parseTime(input: string): number | null {
  const text = input.trim();
  if (!/^(?:\d+:){0,2}\d+(?:\.\d{1,3})?$/.test(text)) return null;
  const parts = text.split(':').map(Number);
  if (parts.length > 1 && parts[parts.length - 1]! >= 60) return null;
  if (parts.length === 3 && parts[1]! >= 60) return null;
  const seconds = parts.reduce((value, part) => value * 60 + part, 0);
  return Number.isFinite(seconds) ? seconds : null;
}

export function rulerStep(pixelsPerSecond: number): number {
  const steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
  return steps.find((step) => step * pixelsPerSecond >= 66) ?? 1200;
}
