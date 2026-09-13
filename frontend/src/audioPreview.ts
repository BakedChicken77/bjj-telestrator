import type { Voiceover } from './model';

export interface PlaybackPlan {
  when: number;
  offsetSec: number;
  durationSec: number;
  effectiveStartSec: number;
}

/** Bound background decoding. Active overlapping clips must all remain audible. */
export function previewWorkingSet(
  clips: readonly Voiceover[],
  mediaTime: number,
  byteBudget = 256 * 1024 * 1024,
): Voiceover[] {
  const start = (clip: Voiceover) => clip.startSec + clip.timingOffsetMs / 1000;
  const end = (clip: Voiceover) => start(clip) + clip.durationSec;
  const active = (clip: Voiceover) => start(clip) <= mediaTime && mediaTime < end(clip);
  const rank = (clip: Voiceover) => (active(clip) ? 0 : start(clip) > mediaTime ? 1 : 2);
  const candidates = clips
    .filter((clip) => end(clip) > mediaTime - 5 && start(clip) <= mediaTime + 30)
    .sort(
      (a, b) =>
        rank(a) - rank(b) || Math.abs(start(a) - mediaTime) - Math.abs(start(b) - mediaTime),
    );
  const selected: Voiceover[] = [];
  let bytes = 0;
  for (const clip of candidates) {
    const size = Math.ceil(clip.durationSec * clip.sampleRate * clip.channels * 4);
    // One long take can exceed the budget; never silently omit an active overlap.
    if (selected.length === 0 || active(clip) || bytes + size <= byteBudget) {
      selected.push(clip);
      bytes += size;
    }
  }
  return selected;
}

/** Audio offsets remain in source seconds even when playback is faster or slower. */
export function clipPlaybackPlan(
  clip: Pick<Voiceover, 'startSec' | 'durationSec' | 'timingOffsetMs' | 'muted'>,
  mediaTime: number,
  contextTime: number,
  bufferDuration: number,
  playbackRate = 1,
): PlaybackPlan | null {
  const effectiveStartSec = clip.startSec + clip.timingOffsetMs / 1000;
  const duration = Math.min(clip.durationSec, bufferDuration);
  const offsetSec = Math.max(0, mediaTime - effectiveStartSec);
  if (clip.muted || duration <= 0 || offsetSec >= duration || playbackRate <= 0) return null;
  return {
    when: contextTime + Math.max(0, (effectiveStartSec - mediaTime) / playbackRate),
    offsetSec,
    durationSec: duration - offsetSec,
    effectiveStartSec,
  };
}

export interface ClockAnchor {
  mediaTime: number;
  contextTime: number;
  playbackRate: number;
}

export function needsAudioResync(
  anchor: ClockAnchor | null,
  mediaTime: number,
  contextTime: number,
  playbackRate: number,
): boolean {
  if (!anchor || anchor.playbackRate !== playbackRate) return true;
  const expected = anchor.mediaTime + (contextTime - anchor.contextTime) * anchor.playbackRate;
  return Math.abs(expected - mediaTime) > 0.05;
}

export function previewGains(
  originalGain: number,
  originalMuted: boolean,
  voiceoverMasterGain: number,
  monitorVolume: number,
  recording: boolean,
) {
  const monitor = Math.min(1, Math.max(0, monitorVolume));
  return {
    original: (originalMuted ? 0 : Math.min(2, Math.max(0, originalGain))) * monitor,
    voiceover: (recording ? 0 : Math.min(2, Math.max(0, voiceoverMasterGain))) * monitor,
  };
}

interface PlayingClip {
  source: AudioBufferSourceNode;
  gain: GainNode;
  clip: Voiceover;
}

/** One audio clock controls every overlapping clip. A seek replaces all scheduled sources. */
export class VoiceoverTransport {
  private playing = new Map<string, PlayingClip>();
  private anchor: ClockAnchor | null = null;

  constructor(
    private readonly context: AudioContext,
    private readonly destination: AudioNode,
  ) {}

  sync(
    mediaTime: number,
    playbackRate: number,
    clips: readonly Voiceover[],
    buffers: ReadonlyMap<string, AudioBuffer>,
    enabled: boolean,
    force = false,
  ): void {
    if (!enabled || this.context.state !== 'running') {
      this.stop();
      return;
    }
    const now = this.context.currentTime;
    if (force || needsAudioResync(this.anchor, mediaTime, now, playbackRate)) {
      this.stop();
      this.anchor = { mediaTime, contextTime: now, playbackRate };
    }
    const anchoredTime = this.anchor
      ? this.anchor.mediaTime + (now - this.anchor.contextTime) * playbackRate
      : mediaTime;
    for (const [id, entry] of this.playing) {
      const clip = clips.find((item) => item.id === id);
      if (
        !clip ||
        clip.muted ||
        clip.startSec + clip.timingOffsetMs / 1000 + clip.durationSec <= anchoredTime
      ) {
        this.stopClip(id);
      } else {
        entry.gain.gain.setTargetAtTime(clip.gain, now, 0.01);
      }
    }
    for (const clip of clips) {
      if (this.playing.has(clip.id) || clip.startSec + clip.timingOffsetMs / 1000 > mediaTime + 2)
        continue;
      const buffer = buffers.get(clip.id);
      if (!buffer) continue;
      // All scheduled fragments use one anchor, including those decoded later.
      // Sampling the video again for each window would introduce seam jitter.
      const plan = clipPlaybackPlan(clip, anchoredTime, now, buffer.duration, playbackRate);
      if (!plan) continue;
      const source = this.context.createBufferSource();
      const gain = this.context.createGain();
      source.buffer = buffer;
      source.playbackRate.value = playbackRate;
      gain.gain.value = clip.gain;
      source.connect(gain);
      gain.connect(this.destination);
      this.playing.set(clip.id, { source, gain, clip });
      source.onended = () => {
        if (this.playing.get(clip.id)?.source === source) {
          source.disconnect();
          gain.disconnect();
          this.playing.delete(clip.id);
        }
      };
      source.start(plan.when, plan.offsetSec, plan.durationSec);
    }
  }

  private stopClip(id: string): void {
    const entry = this.playing.get(id);
    if (!entry) return;
    entry.source.onended = null;
    entry.source.stop();
    entry.source.disconnect();
    entry.gain.disconnect();
    this.playing.delete(id);
  }

  stop(): void {
    for (const id of this.playing.keys()) this.stopClip(id);
    this.anchor = null;
  }
}
