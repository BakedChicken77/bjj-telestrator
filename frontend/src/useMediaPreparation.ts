import { useEffect, useRef, useState } from 'react';
import { api, type MediaJob } from './api';
import type { Project } from './model';
import { nativeAPI } from './native';

const rememberedJob = 'bjj:mediaJob';
const terminal = (job: MediaJob) => ['completed', 'failed', 'cancelled'].includes(job.status);
const message = (error: unknown) =>
  error instanceof Error ? error.message : 'Video preparation could not be completed.';
const errorCode = (error: unknown) =>
  typeof error === 'object' && error !== null && 'code' in error ? error.code : undefined;

export function useMediaPreparation(options: {
  enabled: boolean;
  flush: () => Promise<Project | null>;
  onLoad: (project: Project) => void;
  onBusy: (text: string | null) => void;
  onError: (text: string | null) => void;
  onNotice: (text: string) => void;
}) {
  const callbacks = useRef(options);
  callbacks.current = options;
  const [job, setJob] = useState<MediaJob | null>(null);
  const [statusError, setStatusError] = useState<string | null>(null);
  const upload = useRef<AbortController | null>(null);
  const launchError = useRef<string | null>(null);
  const selected = useRef<string | null>(null);
  const jobId = job?.jobId;

  useEffect(() => {
    if (!options.enabled) return;
    const id = localStorage.getItem(rememberedJob);
    if (!id) return;
    callbacks.current.onBusy('Checking the previous video preparation…');
    let disposed = false;
    void api
      .mediaJob(id)
      .then((next) => {
        if (!disposed) {
          selected.current = id;
          setJob(next);
        }
      })
      .catch((error: unknown) => {
        if (!disposed) {
          callbacks.current.onError(
            `The previous video preparation could not be checked. ${message(error)}`,
          );
          callbacks.current.onBusy(null);
          if (errorCode(error) === 'JOB_MISSING') localStorage.removeItem(rememberedJob);
        }
      });
    return () => {
      disposed = true;
    };
  }, [options.enabled]);

  useEffect(() => {
    if (!jobId) return;
    const id = jobId;
    let disposed = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    async function poll() {
      try {
        const next = await api.mediaJob(id);
        if (disposed) return;
        setJob(next);
        setStatusError(null);
        if (terminal(next)) {
          if (next.status === 'completed') {
            let project: Project;
            try {
              project = await api.project(next.projectId);
            } catch (error) {
              if (errorCode(error) === 'CONNECTION_UNAVAILABLE') throw error;
              callbacks.current.onError(
                `Preparation finished, but this project could not be reopened. ${message(error)}`,
              );
              callbacks.current.onBusy(null);
              localStorage.removeItem(rememberedJob);
              return;
            }
            if (disposed) return;
            callbacks.current.onLoad(project);
            callbacks.current.onNotice(
              next.operation === 'repair'
                ? 'Preview repaired. Drawings, narration and source timing were preserved.'
                : 'Video is ready to review.',
            );
            setJob(null);
          } else if (next.status === 'failed' || launchError.current) {
            callbacks.current.onError(
              launchError.current ??
                next.error ??
                'Video preparation failed. Retry from the original source.',
            );
          } else
            callbacks.current.onNotice(
              'Video preparation cancelled. Existing projects were preserved.',
            );
          if (localStorage.getItem(rememberedJob) === id) localStorage.removeItem(rememberedJob);
          callbacks.current.onBusy(null);
          return;
        }
        callbacks.current.onBusy('Preparing video…');
      } catch (error) {
        if (disposed) return;
        // Keep the operation and cancellation control visible across connection loss.
        setStatusError(`Status unavailable. Retrying… ${message(error)}`);
      }
      if (!disposed) timer = setTimeout(() => void poll(), 500);
    }
    void poll();
    return () => {
      disposed = true;
      clearTimeout(timer);
    };
  }, [jobId]); // Status updates do not start competing polling loops.

  function remember(next: MediaJob) {
    selected.current = next.jobId;
    localStorage.setItem(rememberedJob, next.jobId);
    setStatusError(null);
    setJob(next);
  }
  async function start(file?: File, nativeSource?: 'photos' | 'files', repair = false) {
    callbacks.current.onError(null);
    callbacks.current.onBusy('Preparing video…');
    launchError.current = null;
    let id: string | undefined;
    let controller: AbortController | null = null;
    try {
      const saved = await callbacks.current.flush();
      if (repair) {
        if (!saved) throw new Error('Open a saved project before repairing its preview.');
        remember(await api.repairProxy(saved.projectId, saved.revision));
        return;
      }
      const next = await api.createImportJob();
      id = next.jobId;
      remember(next);
      if (nativeSource) await nativeAPI.importVideo(nativeSource, next.jobId);
      else if (file) {
        controller = new AbortController();
        upload.current = controller;
        await api.importVideo(file, undefined, { jobId: next.jobId, signal: controller.signal });
      }
    } catch (error) {
      if (id && selected.current !== id) return;
      const code =
        typeof error === 'object' && error !== null && 'code' in error ? error.code : undefined;
      if (code !== 'JOB_CANCELLED') launchError.current = message(error);
      if (!id) {
        callbacks.current.onError(message(error));
        callbacks.current.onBusy(null);
      } else {
        setStatusError(message(error));
        // Validation can reject an upload before its handler claims the job.
        // Cancel that unused reservation; never cancel an operation after a lost response.
        if (code !== 'CONNECTION_UNAVAILABLE') {
          const current = await api.mediaJob(id).catch(() => null);
          if (current?.status === 'queued') await api.cancelMediaJob(id).catch(() => undefined);
        }
      }
    } finally {
      if (upload.current === controller) upload.current = null;
    }
  }
  async function cancel() {
    if (!job || terminal(job)) return;
    try {
      const next = await api.cancelMediaJob(job.jobId);
      if (selected.current === next.jobId) setJob(next);
      upload.current?.abort();
    } catch (error) {
      setStatusError(`Cancellation was not confirmed. ${message(error)}`);
    }
  }
  return { job, statusError, cancel, start, dismiss: () => setJob(null) };
}
