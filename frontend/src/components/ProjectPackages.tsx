import { useEffect, useState } from 'react';
import { api, type PackageJob, type SpaceEstimate } from '../api';
import type { Project } from '../model';
import { isNativeIOS } from '../native';
import type { PackageController } from '../usePackages';
import { byteLabel } from './ProjectStorage';

const stages = {
  copying: 'Copying package',
  inspecting: 'Inspecting package',
  packing: 'Building backup',
  extracting: 'Restoring media',
  validating: 'Verifying checksums and media',
  preparing_preview: 'Preparing restored preview',
  ready: 'Package complete',
};
export function PackageStatus({ controller }: { controller: PackageController }) {
  const { job, error } = controller;
  if (!job)
    return error || controller.pendingRequest ? (
      <section className="package-status" aria-label="Project package status">
        {error ? (
          <p role="alert">{error}</p>
        ) : (
          <p role="status">Checking package request status…</p>
        )}
        {controller.pendingRequest && (
          <>
            <button onClick={controller.retry}>Retry package status</button>
            <button onClick={controller.dismiss}>Dismiss package status</button>
          </>
        )}
      </section>
    ) : null;
  const done = ['completed', 'cancelled', 'failed'].includes(job.status);
  const label =
    job.status === 'cancelled'
      ? 'Package work cancelled'
      : job.status === 'failed'
        ? 'Package work failed'
        : job.cancelRequested
          ? 'Cancelling package work…'
          : stages[job.stage];
  return (
    <section className="package-status" aria-label="Project package status">
      <strong role="status">{label}</strong>
      {!done && (
        <progress max={1} value={job.progress ?? undefined} aria-label={stages[job.stage]} />
      )}
      {!done && job.progress !== null && (
        <span aria-hidden="true">{Math.round(job.progress * 100)}%</span>
      )}
      {(job.error || error) && <p role="alert">{job.error || error}</p>}
      {error && <button onClick={controller.retry}>Retry package status</button>}
      {job.status === 'completed' && job.operation === 'restore' && (
        <button onClick={() => void controller.openRestored()}>Open restored project</button>
      )}
      {job.status === 'completed' &&
        job.operation === 'backup' &&
        (isNativeIOS() ? (
          <button onClick={() => void controller.share()}>Save backup to Files or share</button>
        ) : (
          <a className="button" href={`/api/package-jobs/${job.jobId}/file`} download>
            Download editable backup
          </a>
        ))}
      {done ? (
        <>
          <button onClick={controller.dismiss}>Dismiss package status</button>
          <button onClick={() => void controller.remove()}>Remove temporary package</button>
        </>
      ) : (
        <button disabled={job.cancelRequested} onClick={() => void controller.cancel()}>
          Cancel package work
        </button>
      )}
      <small>
        Keep the app open during preparation. Temporary package files stay in the app until you
        remove them.
      </small>
    </section>
  );
}
export function ProjectPackages({
  project,
  busy,
  controller,
}: {
  project: Project | null;
  busy: boolean;
  controller: PackageController;
}) {
  const [includeProxy, setIncludeProxy] = useState(false);
  const [estimate, setEstimate] = useState<SpaceEstimate | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [jobs, setJobs] = useState<PackageJob[]>([]);
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    let active = true;
    setError(null);
    setEstimate(null);
    const projectId = project?.projectId;
    void Promise.allSettled([
      projectId ? api.packageEstimate(projectId, includeProxy) : null,
      api.packageJobs(),
    ]).then(([size, list]) => {
      if (!active) return;
      if (size.status === 'fulfilled') setEstimate(size.value);
      else setError('Backup size could not be checked. Repair missing media or refresh packages.');
      if (list.status === 'fulfilled') setJobs(list.value);
      else setError('Retained packages could not be listed. Refresh packages to retry.');
    });
    return () => {
      active = false;
    };
  }, [
    project?.projectId,
    project?.revision,
    includeProxy,
    controller.job?.status,
    controller.job?.jobId,
    refresh,
  ]);
  return (
    <section className="project-packages" aria-label="Editable project backups">
      <h3>Editable project backups</h3>
      <p>
        A .bjjproj backup includes the original video, drawings and referenced narration. Restore
        creates an independent copy.
      </p>
      {project && (
        <fieldset disabled={busy || controller.pendingRequest}>
          <legend>Back up {project.projectName}</legend>
          <label>
            <input
              type="checkbox"
              checked={includeProxy}
              onChange={(event) => setIncludeProxy(event.target.checked)}
            />{' '}
            Include preview for faster restore
          </label>
          {estimate && (
            <p>
              Estimated backup: {byteLabel(estimate.outputBytes)}. Allow{' '}
              {byteLabel(estimate.requiredBytes)} free while preparing it.
            </p>
          )}
          <button disabled={!estimate} onClick={() => void controller.startBackup(includeProxy)}>
            Back up editable project
          </button>
        </fieldset>
      )}
      {isNativeIOS() ? (
        <button
          disabled={busy || controller.pendingRequest}
          onClick={() => void controller.startRestore()}
        >
          Restore project from Files
        </button>
      ) : (
        <label>
          Restore project package{' '}
          <input
            type="file"
            accept=".bjjproj,.zip,application/zip"
            disabled={busy || controller.pendingRequest}
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              if (file) void controller.startRestore(file);
            }}
          />
        </label>
      )}
      {controller.pending && (
        <div role="group" aria-label="Package opened from Files">
          <p>A project package was opened from Files.</p>
          <button
            disabled={busy || controller.pendingRequest}
            onClick={() => void controller.startRestore(undefined, true)}
          >
            Restore opened package
          </button>
          <button disabled={busy} onClick={() => void controller.dismissPending()}>
            Dismiss opened package
          </button>
        </div>
      )}
      {error && <p role="alert">{error}</p>}
      <details>
        <summary>Retained package operations ({jobs.length})</summary>
        <label>
          Operation{' '}
          <select
            aria-label="Retained package operation"
            disabled={busy}
            value={controller.job?.jobId ?? ''}
            onChange={(event) => {
              const found = jobs.find((job) => job.jobId === event.target.value);
              if (found) controller.track(found);
            }}
          >
            <option value="">Choose an operation</option>
            {jobs.map((job) => (
              <option key={job.jobId} value={job.jobId}>
                {job.operation === 'backup' ? 'Backup' : 'Restore'} · revision{' '}
                {job.projectRevision ?? 'pending'} · {new Date(job.createdAt).toLocaleString()} ·{' '}
                {job.status}
              </option>
            ))}
          </select>
        </label>
        <button disabled={busy} onClick={() => setRefresh((value) => value + 1)}>
          Refresh packages
        </button>
      </details>
      <PackageStatus controller={controller} />
    </section>
  );
}
