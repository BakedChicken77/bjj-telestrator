import { useCallback, useEffect, useState } from 'react';
import { api } from './api';
import { isNativeIOS, nativeBridge } from './native';
import { useEditor } from './store';
import { clearDraft, findDrafts, writeDraft, writerId } from './project/recovery';
import {
  flushActiveSave,
  SaveSession,
  setActiveSave,
  type Draft,
  type SaveState,
} from './project/saveSession';

export function useAutosave() {
  const sessionId = useEditor((state) => state.session);
  const [state, setState] = useState<SaveState>({ status: 'saved', error: null });
  const [recovery, setRecovery] = useState<Draft[]>([]);
  const [recoveryError, setRecoveryError] = useState<string | null>(null);
  useEffect(() => {
    const initial = useEditor.getState().project;
    setRecovery([]);
    setRecoveryError(null);
    setState({ status: 'saved', error: null });
    if (!initial) {
      setActiveSave(null);
      return;
    }
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const session = new SaveSession(initial, {
      save: api.save,
      read: api.project,
      journal: writeDraft,
      clear: clearDraft,
      writerId,
      acknowledge: (target, saved) => useEditor.getState().acknowledge(target, saved),
      notify: setState,
    });
    setActiveSave(session);
    void findDrafts(initial)
      .then((result) => {
        if (!disposed) {
          setRecovery(result.drafts);
          if (result.corrupt)
            setRecoveryError(
              'A recovery draft is damaged. The confirmed project is intact; the draft was retained.',
            );
        }
      })
      .catch(() => {
        if (!disposed)
          setRecoveryError(
            'Recovery storage could not be read. Your confirmed project is still available.',
          );
      });
    const unsubscribe = useEditor.subscribe((next, previous) => {
      if (next.session !== sessionId || next.project === previous.project || !next.project) return;
      session.update(next.project);
      clearTimeout(timer);
      timer = setTimeout(() => {
        void session.flush().catch(() => undefined);
      }, 550);
    });
    const flush = () => {
      void session.flush().catch(() => undefined);
    };
    const hidden = () => {
      if (document.visibilityState === 'hidden') flush();
    };
    const unload = (event: BeforeUnloadEvent) => {
      if (session.dirty) {
        event.preventDefault();
        event.returnValue = '';
      }
    };
    const listener = isNativeIOS() ? nativeBridge.addListener('appSuspending', flush) : null;
    document.addEventListener('visibilitychange', hidden);
    window.addEventListener('beforeunload', unload);
    return () => {
      disposed = true;
      session.dispose();
      setActiveSave(null);
      clearTimeout(timer);
      unsubscribe();
      document.removeEventListener('visibilitychange', hidden);
      window.removeEventListener('beforeunload', unload);
      if (listener) void listener.then((handle) => handle.remove()).catch(() => undefined);
    };
  }, [sessionId]);
  const flush = useCallback(async () => {
    if (!useEditor.getState().project) return null;
    return flushActiveSave();
  }, []);
  return {
    ...state,
    flush,
    recovery,
    recoveryError,
    dismissRecovery: () => setRecovery([]),
    clearDraft,
  };
}
