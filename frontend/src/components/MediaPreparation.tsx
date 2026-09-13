import type { MediaJob } from '../api';

const labels = {
  copying: 'Copying selected video',
  inspecting: 'Inspecting video',
  preparing_preview: 'Preparing preview',
  validating: 'Validating preview',
  ready: 'Ready to review',
};
export function MediaPreparation({
  job,
  error,
  onCancel,
  onDismiss,
}: {
  job: MediaJob;
  error: string | null;
  onCancel: () => void;
  onDismiss: () => void;
}) {
  const done = ['completed', 'failed', 'cancelled'].includes(job.status);
  const label =
    job.status === 'failed'
      ? 'Video preparation failed'
      : job.status === 'cancelled'
        ? 'Video preparation cancelled'
        : job.cancelRequested
          ? 'Cancelling video preparation…'
          : labels[job.stage];
  return (
    <section className="media-preparation" aria-label="Video preparation">
      <strong role="status">{label}</strong>
      {!done && (
        <progress aria-label={labels[job.stage]} max={1} value={job.progress ?? undefined} />
      )}
      {!done && job.progress !== null && (
        <span aria-hidden="true">{Math.round(job.progress * 100)}%</span>
      )}
      {error && <p role="alert">{error}</p>}
      <p>
        Keep the app open. Previews use up to 1920 pixels and 30 fps; original files and source
        timing are preserved.
      </p>
      {done ? (
        <button onClick={onDismiss}>Dismiss preparation status</button>
      ) : (
        <button disabled={job.cancelRequested} onClick={onCancel}>
          Cancel preparation
        </button>
      )}
    </section>
  );
}
