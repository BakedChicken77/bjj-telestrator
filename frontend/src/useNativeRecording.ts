import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { PluginListenerHandle } from '@capacitor/core';
import { flushActiveSave } from './project/saveSession';
import { isNativeIOS, nativeAPI, nativeBridge } from './native';
import { useEditor } from './store';
import { voiceoverSchema, type Voiceover } from './model';
import { recordingStart } from './recording';

function retainClip(projectId: string, clip: Voiceover) {
  const state = useEditor.getState();
  if (
    state.project?.projectId !== projectId ||
    state.project.voiceovers.some((v) => v.id === clip.id)
  )
    return;
  state.edit((project) => {
    project.voiceovers.push(clip);
  });
}

export function useNativeRecording(videoRef: RefObject<HTMLVideoElement | null>) {
  const [state, setState] = useState<'idle' | 'permission' | 'recording' | 'uploading'>('idle');
  const [message, setMessage] = useState('');
  const startTime = useRef<number | undefined>(undefined);
  const projectId = useRef<string | undefined>(undefined);
  const active = useRef(false);
  const stopping = useRef(false);
  const mounted = useRef(true);
  const removeEvents = useRef<() => void>(() => undefined);

  const stop = useCallback(
    (reason = '') => {
      if (!active.current || stopping.current) return;
      stopping.current = true;
      removeEvents.current();
      videoRef.current?.pause();
      if (mounted.current) {
        setState('uploading');
        setMessage(reason);
      }
      void nativeAPI
        .stopRecording(startTime.current)
        .then(async (clip) => {
          if (clip && projectId.current) {
            retainClip(projectId.current, clip);
            await flushActiveSave();
          }
        })
        .catch((cause: unknown) => {
          useEditor
            .getState()
            .setError(cause instanceof Error ? cause.message : 'The recording could not be saved.');
        })
        .finally(() => {
          active.current = false;
          stopping.current = false;
          useEditor.getState().setRecording(false);
          if (mounted.current) setState('idle');
        });
    },
    [videoRef],
  );

  useEffect(() => {
    mounted.current = true;
    if (!isNativeIOS()) return;
    let listener: PluginListenerHandle | undefined;
    let disposed = false;
    void nativeBridge
      .addListener('recordingFinished', (event) => {
        removeEvents.current();
        videoRef.current?.pause();
        if (event.clip) {
          const parsed = voiceoverSchema.safeParse(event.clip);
          if (parsed.success) retainClip(event.projectId, parsed.data);
          else
            useEditor
              .getState()
              .setError(
                'The saved recording has invalid metadata. Reopen the project to recover it.',
              );
        }
        if (event.error) useEditor.getState().setError(event.error);
        active.current = false;
        useEditor.getState().setRecording(false);
        if (mounted.current) {
          setState('idle');
          setMessage(event.reason);
        }
      })
      .then((handle) => {
        if (disposed) void handle.remove();
        else listener = handle;
      })
      .catch((cause: unknown) => {
        useEditor
          .getState()
          .setError(
            cause instanceof Error
              ? cause.message
              : 'Recording interruption notifications are unavailable.',
          );
      });
    return () => {
      mounted.current = false;
      disposed = true;
      removeEvents.current();
      if (listener) void listener.remove();
      if (active.current) stop('Recording saved before leaving the project.');
    };
  }, [stop, videoRef]);

  const start = useCallback(async () => {
    const project = useEditor.getState().project;
    const video = videoRef.current;
    if (!project || !video || useEditor.getState().recording) return;
    try {
      recordingStart(video.currentTime, project.source.durationSec);
      video.pause();
      useEditor.getState().setError(null);
      useEditor.getState().setRecording(true);
      useEditor.getState().setTool('select');
      useEditor.getState().select(null);
      setMessage('');
      setState('permission');
      projectId.current = project.projectId;
      startTime.current = undefined;
      // Persist edits before native interruption handling can append a recovered take.
      await flushActiveSave();
      await nativeBridge.prepareRecording({ projectId: project.projectId });
      active.current = true;
      if (!mounted.current) {
        stop();
        return;
      }
      await video.play();
      const requested = recordingStart(video.currentTime, project.source.durationSec);
      const sentAt = performance.now();
      const { elapsedSec } = await nativeBridge.startRecording({ startSec: requested });
      // Compensate for the small bridge round-trip; clips retain a manual timing nudge.
      const returnLatency = (performance.now() - sentAt) / 2000;
      startTime.current = Math.max(requested, video.currentTime - elapsedSec - returnLatency);
      setState('recording');
      const paused = () => stop('Recording saved when playback stopped.');
      const interrupted = () => stop('Recording saved after a playback interruption.');
      const hidden = () => {
        if (document.hidden) stop('Recording saved before the app left the foreground.');
      };
      for (const name of ['pause', 'ended', 'seeking']) video.addEventListener(name, paused);
      for (const name of ['waiting', 'stalled']) video.addEventListener(name, interrupted);
      document.addEventListener('visibilitychange', hidden);
      removeEvents.current = () => {
        for (const name of ['pause', 'ended', 'seeking']) video.removeEventListener(name, paused);
        for (const name of ['waiting', 'stalled']) video.removeEventListener(name, interrupted);
        document.removeEventListener('visibilitychange', hidden);
      };
    } catch (cause) {
      removeEvents.current();
      video.pause();
      if (active.current) stop();
      else {
        setState('idle');
        useEditor.getState().setRecording(false);
      }
      useEditor
        .getState()
        .setError(
          cause instanceof Error
            ? cause.message
            : 'Unable to open the microphone. Check iPhone Settings → Privacy & Security → Microphone.',
        );
    }
  }, [stop, videoRef]);

  return { state, message, start, stop };
}
