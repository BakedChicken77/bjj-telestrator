import { flushActiveSave } from './project/saveSession';
import { nativeAPI, nativeBridge } from './native';
import { useEditor } from './store';
import { voiceoverSchema, type Voiceover } from './model';
import { newUUID } from './uuid';
import { recordingStart } from './recording';

export type RecordingState = 'idle' | 'permission' | 'recording' | 'uploading';
type Finished = {
  projectId: string;
  sessionId: string;
  clip?: unknown;
  reason: string;
  error?: string;
};
type Attempt = {
  id: string;
  projectId: string;
  video: HTMLVideoElement;
  cancelled: boolean;
  stopping: boolean;
  startSec?: number;
  removeEvents: () => void;
};
async function retainClip(projectId: string, clip: Voiceover) {
  const state = useEditor.getState();
  if (state.project?.projectId !== projectId) return;
  if (!state.project.voiceovers.some((v) => v.id === clip.id))
    state.edit((project) => {
      project.voiceovers.push(clip);
    });
  const current = useEditor.getState().project;
  if (current?.projectId === projectId) await flushActiveSave();
}
/** Each asynchronous continuation and event belongs to one capture attempt. */
export class NativeRecordingSession {
  private attempt?: Attempt;
  constructor(
    private readonly getVideo: () => HTMLVideoElement | null,
    private readonly update: (state: RecordingState, message: string) => void,
  ) {}
  private current(attempt: Attempt) {
    return this.attempt === attempt && !attempt.cancelled && !attempt.stopping;
  }
  private reset(attempt: Attempt, message: string) {
    if (this.attempt !== attempt) return;
    attempt.removeEvents();
    this.attempt = undefined;
    useEditor.getState().setRecording(false);
    this.update('idle', message);
  }
  private error(cause: unknown) {
    useEditor
      .getState()
      .setError(
        cause instanceof Error ? cause.message : 'Recording failed. Tap Record voiceover to retry.',
      );
  }
  async start() {
    const project = useEditor.getState().project;
    const video = this.getVideo();
    if (!project || !video || this.attempt || useEditor.getState().recording) return;
    const attempt: Attempt = {
      id: newUUID(),
      projectId: project.projectId,
      video,
      cancelled: false,
      stopping: false,
      removeEvents: () => undefined,
    };
    this.attempt = attempt;
    try {
      recordingStart(video.currentTime, project.source.durationSec);
      video.pause();
      useEditor.getState().setError(null);
      useEditor.getState().setRecording(true);
      useEditor.getState().setTool('select');
      useEditor.getState().select(null);
      this.update('permission', '');
      const hidden = () => {
        if (document.hidden) void this.stop('Recording saved before the app left the foreground.');
      };
      document.addEventListener('visibilitychange', hidden);
      attempt.removeEvents = () => document.removeEventListener('visibilitychange', hidden);
      await flushActiveSave();
      if (!this.current(attempt)) return;
      await nativeBridge.prepareRecording({ projectId: project.projectId, sessionId: attempt.id });
      if (!this.current(attempt)) return;
      await video.play();
      if (!this.current(attempt)) {
        if (!this.attempt) video.pause();
        return;
      }
      if (video.paused || video.ended || document.hidden)
        throw new Error('Playback stopped before recording began. Tap Record voiceover to retry.');
      const paused = () => {
        void this.stop('Recording saved when playback stopped.');
      };
      const interrupted = () => {
        void this.stop('Recording saved after a playback interruption.');
      };
      for (const name of ['pause', 'ended', 'seeking']) video.addEventListener(name, paused);
      for (const name of ['waiting', 'stalled']) video.addEventListener(name, interrupted);
      attempt.removeEvents = () => {
        for (const name of ['pause', 'ended', 'seeking']) video.removeEventListener(name, paused);
        for (const name of ['waiting', 'stalled']) video.removeEventListener(name, interrupted);
        document.removeEventListener('visibilitychange', hidden);
      };
      const requested = recordingStart(video.currentTime, project.source.durationSec);
      const sentAt = performance.now();
      const { elapsedSec } = await nativeBridge.startRecording({
        startSec: requested,
        sessionId: attempt.id,
      });
      if (!this.current(attempt)) return;
      const latency = (performance.now() - sentAt) / 2000;
      attempt.startSec = Math.min(
        project.source.durationSec - 0.05,
        Math.max(requested, video.currentTime - elapsedSec - latency),
      );
      this.update('recording', '');
    } catch (cause) {
      if (!this.current(attempt)) return;
      this.error(cause);
      await this.stop();
    }
  }
  async stop(reason = '') {
    const attempt = this.attempt;
    if (!attempt || attempt.stopping) return;
    attempt.cancelled = true;
    attempt.stopping = true;
    attempt.removeEvents();
    attempt.video.pause();
    this.update('uploading', '');
    let message = '';
    try {
      const clip = await nativeAPI.stopRecording(attempt.id, attempt.startSec);
      if (clip) {
        await retainClip(attempt.projectId, clip);
        message = reason || 'Recording saved.';
      } else message = 'No recording was saved. Tap Record voiceover to retry.';
    } catch (cause) {
      this.error(cause);
    } finally {
      this.reset(attempt, message);
    }
  }
  async finished(event: Finished) {
    const attempt = this.attempt;
    if (
      !attempt ||
      event.sessionId !== attempt.id ||
      event.projectId !== attempt.projectId ||
      attempt.stopping
    )
      return;
    attempt.cancelled = true;
    attempt.stopping = true;
    attempt.removeEvents();
    attempt.video.pause();
    this.update('uploading', '');
    let message =
      'Recording interrupted before a clip could be saved. Tap Record voiceover to retry.';
    try {
      if (event.clip) {
        await retainClip(event.projectId, voiceoverSchema.parse(event.clip));
        message = event.reason;
      }
      if (event.error) this.error(new Error(event.error));
    } catch (cause) {
      this.error(cause);
    } finally {
      this.reset(attempt, message);
    }
  }
}
