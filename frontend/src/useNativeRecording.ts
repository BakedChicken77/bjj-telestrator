import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { PluginListenerHandle } from '@capacitor/core';
import { isNativeIOS, nativeBridge } from './native';
import { useEditor } from './store';
import { NativeRecordingSession, type RecordingState } from './nativeRecordingSession';

export function useNativeRecording(videoRef: RefObject<HTMLVideoElement | null>) {
  const [state, setState] = useState<RecordingState>('idle');
  const [message, setMessage] = useState('');
  const session = useRef<NativeRecordingSession | null>(null);
  const ready = useRef<Promise<void> | null>(null);
  useEffect(() => {
    if (!isNativeIOS()) return;
    let disposed = false;
    let listener: PluginListenerHandle | undefined;
    const controller = new NativeRecordingSession(
      () => videoRef.current,
      (next, text) => {
        if (!disposed) {
          setState(next);
          setMessage(text);
        }
      },
    );
    session.current = controller;
    const registration = nativeBridge
      .addListener('recordingFinished', (event) => {
        void controller.finished(event);
      })
      .then((handle) => {
        if (disposed) void handle.remove();
        else listener = handle;
      });
    ready.current = registration;
    void registration.catch(() => undefined);
    return () => {
      disposed = true;
      session.current = null;
      ready.current = null;
      void controller.stop();
      if (listener) void listener.remove();
    };
  }, [videoRef]);
  const start = useCallback(async () => {
    const controller = session.current;
    try {
      await ready.current;
      if (controller && session.current === controller) await controller.start();
    } catch {
      useEditor
        .getState()
        .setError(
          'Recording interruption notifications are unavailable. Reopen the project and retry.',
        );
    }
  }, []);
  const stop = useCallback((reason = '') => {
    void session.current?.stop(reason);
  }, []);
  return { state, message, start, stop };
}
