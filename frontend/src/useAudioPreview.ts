import { useEffect, useRef, useState, type RefObject } from 'react';
import type { Project } from './model';
import { useEditor } from './store';
import { previewGains, previewWorkingSet, VoiceoverTransport } from './audioPreview';
import { voiceoverURL } from './native';

interface MediaGraph {
  context: AudioContext;
  source: MediaElementAudioSourceNode;
  originalGain: GainNode;
  voiceoverGain: GainNode;
  releaseTimer?: ReturnType<typeof setTimeout>;
}

// React StrictMode can tear down and reattach an effect to the same video node.
// A MediaElementAudioSource can only be created once for that node.
const graphs = new WeakMap<HTMLVideoElement, MediaGraph>();

function acquireGraph(video: HTMLVideoElement): MediaGraph {
  const previous = graphs.get(video);
  if (previous && previous.context.state !== 'closed') {
    if (previous.releaseTimer !== undefined) clearTimeout(previous.releaseTimer);
    previous.releaseTimer = undefined;
    return previous;
  }
  const context = new AudioContext({ latencyHint: 'interactive' });
  const source = context.createMediaElementSource(video);
  const originalGain = context.createGain();
  const voiceoverGain = context.createGain();
  source.connect(originalGain);
  originalGain.connect(context.destination);
  voiceoverGain.connect(context.destination);
  const graph = { context, source, originalGain, voiceoverGain };
  graphs.set(video, graph);
  return graph;
}

function releaseGraph(graph: MediaGraph): void {
  graph.releaseTimer = setTimeout(() => {
    graph.source.disconnect();
    graph.originalGain.disconnect();
    graph.voiceoverGain.disconnect();
    void graph.context.close().catch(() => undefined);
  }, 0);
}

interface Configuration {
  project: Project;
  monitorVolume: number;
  recording: boolean;
}

export class AudioPreview {
  private graph: MediaGraph;
  private transport: VoiceoverTransport;
  private buffers = new Map<string, AudioBuffer>();
  private loading = new Map<string, AbortController>();
  private failed = new Set<string>();
  private disposed = false;
  private configuration: Configuration;
  private clipSignature = '';
  private interval: ReturnType<typeof setInterval>;
  private waiting = false;
  private cacheTime = -Infinity;
  private gestureTarget: Window;

  constructor(
    private readonly video: HTMLVideoElement,
    initial: Configuration,
    private readonly onLoading: (loading: boolean) => void,
  ) {
    this.configuration = initial;
    this.graph = acquireGraph(video);
    this.transport = new VoiceoverTransport(this.graph.context, this.graph.voiceoverGain);
    this.gestureTarget = window;
    video.volume = 1;
    video.muted = false;
    video.addEventListener('play', this.resume);
    video.addEventListener('playing', this.playing);
    video.addEventListener('pause', this.stop);
    video.addEventListener('ended', this.stop);
    video.addEventListener('seeking', this.stop);
    video.addEventListener('seeked', this.resync);
    video.addEventListener('ratechange', this.resync);
    video.addEventListener('waiting', this.stalled);
    video.addEventListener('canplay', this.playing);
    this.gestureTarget.addEventListener('pointerdown', this.resume, true);
    this.gestureTarget.addEventListener('keydown', this.resume, true);
    this.interval = setInterval(this.tick, 40);
    this.configure(initial);
  }

  configure(next: Configuration): void {
    this.configuration = next;
    const { project, monitorVolume, recording } = next;
    const gains = previewGains(
      project.settings.originalAudioGain,
      project.settings.originalAudioMuted,
      project.settings.voiceoverMasterGain,
      monitorVolume,
      recording,
    );
    const now = this.graph.context.currentTime;
    this.graph.originalGain.gain.setTargetAtTime(gains.original, now, 0.01);
    this.graph.voiceoverGain.gain.setTargetAtTime(gains.voiceover, now, 0.01);
    const signature = JSON.stringify(project.voiceovers);
    if (signature !== this.clipSignature) {
      this.clipSignature = signature;
      const ids = new Set(project.voiceovers.map((clip) => clip.id));
      for (const id of this.buffers.keys()) if (!ids.has(id)) this.buffers.delete(id);
      for (const [id, controller] of this.loading) if (!ids.has(id)) controller.abort();
      this.transport.stop();
      this.preload();
      this.onLoading(this.loading.size > 0);
    }
    if (recording) this.transport.stop();
    this.tick();
  }

  private readonly resume = (): void => {
    if (this.disposed) return;
    if (this.graph.context.state === 'suspended') {
      void this.graph.context
        .resume()
        .then(() => {
          if (!this.disposed) this.tick();
        })
        .catch(() => {
          if (!this.disposed)
            useEditor
              .getState()
              .setError('Audio preview could not start. Click Play again to enable browser audio.');
        });
    }
    // A later user gesture also retries a transient backend or decode failure.
    if (this.failed.size) {
      this.failed.clear();
      this.preload();
    }
  };

  private readonly playing = (): void => {
    this.waiting = false;
    this.tick();
  };
  private readonly stalled = (): void => {
    this.waiting = true;
    this.transport.stop();
  };
  private readonly stop = (): void => {
    this.transport.stop();
  };
  private readonly resync = (): void => {
    this.transport.stop();
    this.waiting = false;
    this.tick();
  };

  private readonly tick = (): void => {
    if (this.disposed) return;
    if (Math.abs(this.video.currentTime - this.cacheTime) >= 0.5) {
      this.cacheTime = this.video.currentTime;
      this.preload();
    }
    const { project, recording } = this.configuration;
    const enabled =
      !recording &&
      !this.video.paused &&
      !this.video.ended &&
      !this.video.seeking &&
      !this.waiting &&
      this.video.readyState >= 3;
    this.transport.sync(
      this.video.currentTime,
      this.video.playbackRate,
      project.voiceovers,
      this.buffers,
      enabled,
    );
  };

  private preload(): void {
    if (this.disposed) return;
    const wanted = previewWorkingSet(this.configuration.project.voiceovers, this.video.currentTime);
    const ids = new Set(wanted.map((clip) => clip.id));
    for (const id of this.buffers.keys()) if (!ids.has(id)) this.buffers.delete(id);
    for (const [id, controller] of this.loading) if (!ids.has(id)) controller.abort();
    // Only a bounded neighborhood is decoded. The source video is always streamed.
    const pending = wanted.filter(
      (clip) =>
        !this.buffers.has(clip.id) && !this.loading.has(clip.id) && !this.failed.has(clip.id),
    );
    for (const clip of pending.slice(0, Math.max(0, 2 - this.loading.size))) {
      const controller = new AbortController();
      this.loading.set(clip.id, controller);
      this.onLoading(true);
      const projectId = this.configuration.project.projectId;
      void voiceoverURL(projectId, clip.id)
        .then((url) =>
          fetch(url, {
            signal: controller.signal,
          }),
        )
        .then(async (response) => {
          if (!response.ok) throw new Error('Voiceover audio is unavailable');
          const encoded = await response.arrayBuffer();
          return this.graph.context.decodeAudioData(encoded);
        })
        .then((buffer) => {
          if (
            !this.disposed &&
            !controller.signal.aborted &&
            this.configuration.project.voiceovers.some((item) => item.id === clip.id)
          ) {
            this.buffers.set(clip.id, buffer);
            this.tick();
          }
        })
        .catch(() => {
          if (!this.disposed && !controller.signal.aborted) {
            this.failed.add(clip.id);
            useEditor
              .getState()
              .setError(
                'A voiceover could not be prepared for preview. Check the backend connection, then click Play to retry.',
              );
          }
        })
        .finally(() => {
          this.loading.delete(clip.id);
          if (!this.disposed) {
            this.preload();
            this.onLoading(this.loading.size > 0);
          }
        });
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    clearInterval(this.interval);
    this.transport.stop();
    for (const controller of this.loading.values()) controller.abort();
    this.loading.clear();
    this.buffers.clear();
    this.video.removeEventListener('play', this.resume);
    this.video.removeEventListener('playing', this.playing);
    this.video.removeEventListener('pause', this.stop);
    this.video.removeEventListener('ended', this.stop);
    this.video.removeEventListener('seeking', this.stop);
    this.video.removeEventListener('seeked', this.resync);
    this.video.removeEventListener('ratechange', this.resync);
    this.video.removeEventListener('waiting', this.stalled);
    this.video.removeEventListener('canplay', this.playing);
    this.gestureTarget.removeEventListener('pointerdown', this.resume, true);
    this.gestureTarget.removeEventListener('keydown', this.resume, true);
    releaseGraph(this.graph);
  }
}

/** Kept separate from the frame-rendering state; changes only with project edits or controls. */
export function useAudioPreview(
  videoRef: RefObject<HTMLVideoElement | null>,
  project: Project | null,
  monitorVolume: number,
  recording: boolean,
): { loading: boolean } {
  const engine = useRef<AudioPreview | null>(null);
  const [loading, setLoading] = useState(false);
  const latest = useRef<Configuration | null>(null);
  latest.current = project ? { project, monitorVolume, recording } : null;
  const projectId = project?.projectId;

  useEffect(() => {
    const video = videoRef.current;
    const initial = latest.current;
    if (!video || !initial) return;
    try {
      engine.current = new AudioPreview(video, initial, setLoading);
    } catch {
      useEditor
        .getState()
        .setError(
          'Web Audio could not initialize. Reopen the project in a current desktop Chrome or Edge browser.',
        );
    }
    return () => {
      engine.current?.dispose();
      engine.current = null;
    };
  }, [projectId, videoRef]);

  useEffect(() => {
    if (project) engine.current?.configure({ project, monitorVolume, recording });
  }, [project, monitorVolume, recording]);

  return { loading };
}
