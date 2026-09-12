import { useState } from 'react';
import { api, type ExportJob } from '../api';

export function ExportRecovery({
  job,
  revision,
  dirty,
  onJob,
  onError,
}: {
  job: ExportJob;
  revision: number;
  dirty: boolean;
  onJob: (job: ExportJob) => void;
  onError: (error: unknown) => void;
}) {
  const [pending, setPending] = useState(false);
  const terminal = ['completed', 'failed', 'cancelled'].includes(job.status);
  async function run(action: () => Promise<ExportJob>) {
    setPending(true);
    try {
      onJob(await action());
    } catch (error) {
      onError(error);
    } finally {
      setPending(false);
    }
  }
  return (
    <div className="export-recovery">
      <p>
        {job.projectRevision
          ? `Saved revision ${job.projectRevision}`
          : 'Older export · revision unavailable'}
        {job.projectRevision !== undefined &&
          (job.projectRevision !== revision || dirty) &&
          ' · Earlier than current edits'}
        {job.retryOf && ' · Retried from the beginning'}
      </p>
      {job.status === 'completed' && job.outputAvailable === false && (
        <p>MP4 removed. Its saved retry input is retained.</p>
      )}
      {terminal && job.retryAvailable && (
        <button disabled={pending} onClick={() => void run(() => api.retryExport(job.jobId))}>
          {pending ? 'Working…' : `Retry revision ${job.projectRevision} from start`}
        </button>
      )}
      {job.status === 'completed' && job.outputAvailable !== false && (
        <button
          disabled={pending}
          onClick={() => {
            if (
              window.confirm(
                job.retryAvailable
                  ? 'Remove this completed MP4 from this device? Its saved revision can be rendered again.'
                  : 'Remove this older MP4? It has no saved retry input, so its exact prior edits may not be reproducible.',
              )
            ) {
              void run(() => api.removeExportFile(job.jobId));
            }
          }}
        >
          Remove MP4
        </button>
      )}
      {terminal && !job.retryAvailable && (
        <p>
          This older export has no retry input. Render the current review to create a new export.
        </p>
      )}
    </div>
  );
}
