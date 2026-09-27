import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import { api } from './api';
import { useEditor } from './store';
import { chooseRecordingFormat, recordingStart } from './recording';
import { isNativeIOS } from './native';
import { useNativeRecording } from './useNativeRecording';

type RecordingState = 'idle' | 'permission' | 'recording' | 'uploading';

export function useRecording(videoRef: RefObject<HTMLVideoElement | null>) {
  const nativeRecording = useNativeRecording(videoRef);
  const [state, setState] = useState<RecordingState>('idle');
  const [message, setMessage] = useState('');
  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const mounted = useRef(true);
  const cleanupListeners = useRef<() => void>(() => undefined);
  const session = useRef(0);

  const stop = useCallback(
    (reason = '') => {
      const recorder = recorderRef.current;
      if (!recorder || recorder.state === 'inactive') return;
      cleanupListeners.current();
      if (reason) setMessage(reason);
      recorder.stop();
      videoRef.current?.pause();
      streamRef.current?.getTracks().forEach((track) => track.stop());
    },
    [videoRef],
  );

  useEffect(() => {
    mounted.current = true;
    const beforeUnload = (event: BeforeUnloadEvent) => {
      if (useEditor.getState().recording) {
        event.preventDefault();
        event.returnValue = '';
      }
    };
    window.addEventListener('beforeunload', beforeUnload);
    return () => {
      mounted.current = false;
      session.current += 1;
      cleanupListeners.current();
      if (recorderRef.current?.state !== 'inactive') recorderRef.current?.stop();
      streamRef.current?.getTracks().forEach((track) => track.stop());
      useEditor.getState().setRecording(false);
      window.removeEventListener('beforeunload', beforeUnload);
    };
  }, []);

  const start = useCallback(async () => {
    const project = useEditor.getState().project;
    const video = videoRef.current;
    if (!project || !video || useEditor.getState().recording) return;
    const token = ++session.current;
    setMessage('');
    useEditor.getState().setError(null);
    try {
      if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined')
        throw new Error(
          'Microphone recording is unavailable. Open the local app in a current desktop Chrome or Edge browser.',
        );
      const format = chooseRecordingFormat((mime) => MediaRecorder.isTypeSupported(mime));
      if (!format)
        throw new Error(
          'This browser cannot record a supported audio format. Use current Chrome or Edge.',
        );
      recordingStart(video.currentTime, project.source.durationSec);
      video.pause();
      useEditor.getState().setRecording(true);
      useEditor.getState().setTool('select');
      useEditor.getState().select(null);
      setState('permission');
      let permission: PermissionState | undefined;
      try {
        permission = (await navigator.permissions?.query({ name: 'microphone' as PermissionName }))
          ?.state;
      } catch {
        // Some browsers do not expose microphone state through the Permissions API.
      }
      if (permission === 'denied') {
        throw new DOMException('Microphone access is denied.', 'NotAllowedError');
      }
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: false,
      });
      if (!mounted.current || token !== session.current) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      streamRef.current = stream;
      const recorder = new MediaRecorder(stream, {
        mimeType: format.mimeType,
        audioBitsPerSecond: 128000,
      });
      recorderRef.current = recorder;
      const chunks: BlobPart[] = [];
      let startSec = video.currentTime;
      recorder.addEventListener('dataavailable', (event) => {
        if (event.data.size > 0) chunks.push(event.data);
      });
      recorder.addEventListener('error', () => {
        useEditor
          .getState()
          .setError(
            'The microphone recording failed. Check the microphone connection and try again.',
          );
        stop();
      });
      recorder.addEventListener('stop', () => {
        cleanupListeners.current();
        stream.getTracks().forEach((track) => track.stop());
        recorderRef.current = null;
        streamRef.current = null;
        if (!mounted.current || token !== session.current) return;
        setState('uploading');
        const recording = new Blob(chunks, { type: format.mimeType });
        const save = async () => {
          try {
            if (recording.size < 100)
              throw new Error(
                'The recording was too short. Record at least a moment of commentary, then stop.',
              );
            const clip = await api.uploadVoiceover(
              project.projectId,
              recording,
              startSec,
              format.extension,
            );
            if (!mounted.current || token !== session.current) return;
            if (useEditor.getState().project?.projectId === project.projectId)
              useEditor.getState().edit((draft) => {
                draft.voiceovers.push(clip);
              });
          } catch (cause) {
            if (mounted.current)
              useEditor
                .getState()
                .setError(
                  cause instanceof Error
                    ? cause.message
                    : 'Unable to save the voiceover. Check the backend connection.',
                );
          } finally {
            if (mounted.current && token === session.current) {
              setState('idle');
              useEditor.getState().setRecording(false);
            }
          }
        };
        void save();
      });
      await video.play();
      if (!mounted.current || token !== session.current) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      startSec = recordingStart(video.currentTime, project.source.durationSec);
      recorder.start(250);
      setState('recording');
      const ended = () => stop('Recording stopped at the end of the video.');
      const paused = () => stop('Recording stopped with video playback.');
      const stalled = () =>
        stop('Playback buffered, so this clip was stopped to keep its timing accurate.');
      const seeking = () => stop('Recording stopped because playback moved to another time.');
      video.addEventListener('ended', ended);
      video.addEventListener('pause', paused);
      video.addEventListener('waiting', stalled);
      video.addEventListener('stalled', stalled);
      video.addEventListener('seeking', seeking);
      stream.getAudioTracks().forEach((track) => track.addEventListener('ended', paused));
      cleanupListeners.current = () => {
        video.removeEventListener('ended', ended);
        video.removeEventListener('pause', paused);
        video.removeEventListener('waiting', stalled);
        video.removeEventListener('stalled', stalled);
        video.removeEventListener('seeking', seeking);
        stream.getAudioTracks().forEach((track) => track.removeEventListener('ended', paused));
      };
    } catch (cause) {
      cleanupListeners.current();
      streamRef.current?.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
      video.pause();
      if (mounted.current && token === session.current) {
        setState('idle');
        useEditor.getState().setRecording(false);
        const reason =
          cause instanceof DOMException &&
          (cause.name === 'NotAllowedError' || cause.name === 'PermissionDeniedError')
            ? 'Microphone permission was denied. Allow the microphone in the browser’s site controls, then record again.'
            : cause instanceof DOMException && cause.name === 'NotFoundError'
              ? 'No microphone was found. Connect a microphone, then record again.'
              : cause instanceof DOMException && cause.name === 'NotSupportedError'
                ? 'The browser or selected microphone does not support audio recording. Select a working microphone in Windows sound settings and try current Chrome or Edge.'
                : cause instanceof DOMException && cause.name === 'NotReadableError'
                  ? 'The microphone could not be opened. Check its Windows privacy permission and whether another application is using it, then try again.'
                  : cause instanceof Error
                    ? cause.message
                    : 'Unable to start the microphone.';
        useEditor.getState().setError(reason);
      }
    }
  }, [stop, videoRef]);

  return isNativeIOS() ? nativeRecording : { state, message, start, stop };
}
