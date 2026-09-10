import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from './api';
import type { Project } from './model';

export function useAutosave(project: Project | null) {
  const [status, setStatus] = useState<'saved' | 'pending' | 'saving' | 'failed'>('saved');
  const [error, setError] = useState<string | null>(null);
  const latest = useRef(project);
  const saved = useRef(project);
  const queue = useRef<Promise<void>>(Promise.resolve());
  const activeId = useRef(project?.projectId);
  latest.current = project;

  const flush = useCallback(async () => {
    const target = latest.current;
    if (!target) return;
    const save = queue.current
      .catch(() => undefined)
      .then(async () => {
        if (saved.current === target) return;
        if (latest.current?.projectId === target.projectId) setStatus('saving');
        try {
          await api.save(target);
          if (latest.current?.projectId === target.projectId) {
            saved.current = target;
            setError(null);
            setStatus(latest.current === target ? 'saved' : 'pending');
          }
        } catch (cause) {
          if (latest.current?.projectId === target.projectId) {
            setStatus('failed');
            setError(cause instanceof Error ? cause.message : 'Unable to save project.');
          }
          throw cause;
        }
      });
    queue.current = save;
    await save;
  }, []);

  useEffect(() => {
    if (activeId.current !== project?.projectId) {
      activeId.current = project?.projectId;
      saved.current = project;
      setStatus('saved');
      setError(null);
      return;
    }
    if (!project || saved.current === project) return;
    setStatus('pending');
    const timer = window.setTimeout(() => {
      void flush().catch(() => undefined);
    }, 550);
    return () => window.clearTimeout(timer);
  }, [project, flush]);

  useEffect(() => {
    const onHidden = () => {
      if (document.visibilityState === 'hidden') void flush().catch(() => undefined);
    };
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      if (latest.current && latest.current !== saved.current) {
        event.preventDefault();
        event.returnValue = '';
      }
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    document.addEventListener('visibilitychange', onHidden);
    return () => {
      window.removeEventListener('beforeunload', onBeforeUnload);
      document.removeEventListener('visibilitychange', onHidden);
    };
  }, [flush]);

  return { status, error, flush };
}
