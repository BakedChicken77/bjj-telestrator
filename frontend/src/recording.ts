export const RECORDING_MIME_TYPES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
  'audio/mp4',
];

export function chooseRecordingFormat(
  isSupported: (mimeType: string) => boolean,
): { mimeType: string; extension: string } | null {
  const mimeType = RECORDING_MIME_TYPES.find(isSupported);
  if (!mimeType) return null;
  return {
    mimeType,
    extension: mimeType.includes('ogg') ? 'ogg' : mimeType.includes('mp4') ? 'm4a' : 'webm',
  };
}

export function recordingStart(mediaTime: number, duration: number): number {
  if (
    !Number.isFinite(mediaTime) ||
    !Number.isFinite(duration) ||
    mediaTime < 0 ||
    duration - mediaTime < 0.1
  )
    throw new Error('Seek to at least 0.1 seconds before the end to record commentary.');
  return mediaTime;
}

export function clampVoiceoverStart(
  startSec: number,
  durationSec: number,
  offsetMs: number,
  videoDuration: number,
): number {
  return Math.max(
    Math.max(0, -offsetMs / 1000),
    Math.min(startSec, videoDuration - durationSec - offsetMs / 1000),
  );
}

export function clampVoiceoverOffset(
  offsetMs: number,
  startSec: number,
  durationSec: number,
  videoDuration: number,
): number {
  return Math.max(
    Math.max(-60000, -startSec * 1000),
    Math.min(offsetMs, 60000, (videoDuration - startSec - durationSec) * 1000),
  );
}
