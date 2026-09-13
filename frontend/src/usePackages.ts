import { useCallback, useEffect, useRef, useState } from 'react';
import { api, type PackageJob, type PackageRequest } from './api';
import type { Project } from './model';
import { isNativeIOS, nativeBridge } from './native';

const key = 'bjj:packageJob';
const terminal = (job: PackageJob) => ['completed', 'failed', 'cancelled'].includes(job.status);
function remembered(name: string) {
  try {
    return localStorage.getItem(name);
  } catch {
    return null;
  }
}
function remember(name: string, value: string | null) {
  try {
    if (value) localStorage.setItem(name, value);
    else localStorage.removeItem(name);
  } catch {
    /* Durable jobs remain listed by the service. */
  }
}
export function usePackages({
  enabled,
  flush,
  onBusy,
  onLoad,
  onError,
  onNotice,
}: {
  enabled: boolean;
  flush: () => Promise<Project | null>;
  onBusy: (message: string | null) => void;
  onLoad: (project: Project) => void;
  onError: (message: string | null) => void;
  onNotice: (message: string) => void;
}) {
  const [id, setId] = useState(() => remembered(key));
  const [job, setJob] = useState<PackageJob | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const generation = useRef(0);
  const starting = useRef(false);
  const callbacks = useRef({ onBusy, onLoad, onError, onNotice });
  useEffect(() => {
    callbacks.current = { onBusy, onLoad, onError, onNotice };
  }, [onBusy, onLoad, onError, onNotice]);
  const track = useCallback((next: PackageJob) => {
    remember(key, next.jobId);
    setId(next.jobId);
    setJob(next);
    setError(null);
    setRefresh((value) => value + 1);
  }, []);
  useEffect(() => {
    if (!enabled || !isNativeIOS()) return;
    let active = true;
    void nativeBridge
      .getPendingPackage()
      .then(({ available }) => {
        if (active) setPending(available);
      })
      .catch(() => {
        if (active) setError('Files could not be checked. Open the package from Files again.');
      });
    const listener = nativeBridge.addListener('packageOpened', () => setPending(true));
    return () => {
      active = false;
      void listener.then((handle) => handle.remove()).catch(() => undefined);
    };
  }, [enabled]);
  useEffect(() => {
    if (!enabled || !id) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const token = ++generation.current;
    async function poll() {
      try {
        const next = await api.packageJob(id!);
        if (!active || token !== generation.current) return;
        setJob(next);
        setError(null);
        if (!terminal(next)) {
          callbacks.current.onBusy(
            next.operation === 'backup'
              ? 'Preparing editable backup…'
              : 'Restoring editable project…',
          );
          timer = setTimeout(() => void poll(), 500);
        } else {
          callbacks.current.onBusy(null);
        }
      } catch (cause) {
        if (!active) return;
        setError(
          cause instanceof Error ? cause.message : 'Package status is unavailable. Retry status.',
        );
        // Keep the job handle: a lost connection does not cancel server work.
      }
    }
    void poll();
    return () => {
      active = false;
      if (timer) clearTimeout(timer);
    };
  }, [enabled, id, refresh]);

  async function createAndTrack(options: Omit<PackageRequest, 'requestId'>) {
    const requestId = crypto.randomUUID();
    // Remember before sending: the service may accept a request whose response
    // is lost. Retry status against this ID instead of creating another job.
    remember(key, requestId);
    try {
      const created = await api.createPackage({ ...options, requestId });
      track(created);
      return created;
    } catch (cause) {
      setId(requestId);
      setJob(null);
      setError(
        'The package request outcome is unconfirmed. Check its status before starting another.',
      );
      setRefresh((value) => value + 1);
      throw cause;
    }
  }
  async function startBackup(includeProxy: boolean) {
    if (starting.current || (id && !job)) return;
    starting.current = true;
    onBusy('Preparing editable backup…');
    onError(null);
    try {
      const saved = await flush();
      if (!saved) throw new Error('Open a saved project before making a backup.');
      await createAndTrack({
        operation: 'backup',
        projectId: saved.projectId,
        expectedRevision: saved.revision,
        includeProxy,
      });
    } catch (cause) {
      onError(cause instanceof Error ? cause.message : 'Backup could not start.');
      onBusy(null);
    } finally {
      starting.current = false;
    }
  }
  async function startRestore(file?: File, fromInbox = false) {
    if (starting.current || (id && !job)) return;
    starting.current = true;
    onBusy('Restoring editable project…');
    onError(null);
    let created: PackageJob | undefined;
    try {
      await flush();
      created = await createAndTrack({ operation: 'restore' });
      if (isNativeIOS()) {
        const result = await nativeBridge.importPackage({ jobId: created.jobId, fromInbox });
        if (fromInbox) setPending(false);
        if (result.job) track(result.job);
        else if (result.cancelled) track(await api.packageJob(created.jobId));
      } else {
        if (!file) throw new Error('Choose a .bjjproj backup.');
        track(await api.uploadPackage(created.jobId, file));
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The package could not be restored.');
      if (created) {
        try {
          const status = await api.packageJob(created.jobId);
          if (status.status === 'queued') track(await api.cancelPackage(created.jobId));
        } catch {
          /* Retain the handle for retry after reconnection. */
        }
      }
      onBusy(null);
    } finally {
      starting.current = false;
    }
  }
  async function cancel() {
    if (!id) return;
    try {
      track(await api.cancelPackage(id));
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Cancellation could not be confirmed. Retry status.',
      );
    }
  }
  async function remove() {
    if (!id) return;
    try {
      await api.removePackage(id);
      remember(key, null);
      setId(null);
      setJob(null);
      setError(null);
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : 'The temporary package could not be removed.',
      );
    }
  }
  async function share() {
    if (!id) return;
    try {
      const result = await nativeBridge.sharePackage({ jobId: id });
      onNotice(
        result.completed
          ? 'Backup shared. Keep a copy in Files or another chosen location.'
          : 'Backup sharing cancelled.',
      );
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The backup could not be shared.');
    }
  }
  async function openRestored() {
    if (!job || job.operation !== 'restore' || job.status !== 'completed') return;
    onBusy('Opening restored project…');
    try {
      await flush();
      onLoad(await api.project(job.projectId));
      onNotice('Opened an independent, editable project copy.');
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : 'The restored project could not be opened.',
      );
    } finally {
      onBusy(null);
    }
  }
  async function dismissPending() {
    try {
      await nativeBridge.discardPendingPackage();
      setPending(false);
    } catch {
      setError('The Files request could not be dismissed. Try again.');
    }
  }
  return {
    job,
    error,
    pending,
    pendingRequest: !!id && !job,
    refresh,
    track,
    startBackup,
    startRestore,
    cancel,
    remove,
    share,
    openRestored,
    dismissPending,
    retry: () => setRefresh((value) => value + 1),
    dismiss: () => {
      remember(key, null);
      setId(null);
      setJob(null);
      setError(null);
      onBusy(null);
    },
  };
}
export type PackageController = ReturnType<typeof usePackages>;
