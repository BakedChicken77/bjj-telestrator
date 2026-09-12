import { useEffect, useState } from 'react';
import { api, type ProjectStorage as Storage } from '../api';

export function byteLabel(value: number) {
  if (value < 1024) return `${value} B`;
  const unit = Math.min(3, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** unit).toFixed(1)} ${['B', 'KiB', 'MiB', 'GiB'][unit]}`;
}

export function ProjectStorage({
  projectId,
  revision,
  outputs,
}: {
  projectId: string;
  revision: number;
  outputs: string;
}) {
  const [storage, setStorage] = useState<Storage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    void api
      .storage(projectId)
      .then((result) => {
        if (active) setStorage(result);
      })
      .catch((cause: unknown) => {
        if (active)
          setError(cause instanceof Error ? cause.message : 'Could not inspect storage. Retry.');
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [projectId, revision, outputs, refresh]);
  return (
    <details className="project-storage">
      <summary>Project storage{storage ? ` · ${byteLabel(storage.totalBytes)}` : ''}</summary>
      {storage && (
        <>
          <table>
            <caption>Files retained on this device</caption>
            <tbody>
              {(
                [
                  ['Original video', storage.sourceBytes],
                  ['Editing proxy', storage.proxyBytes],
                  ['Recordings (including removed takes)', storage.recordingBytes],
                  ['Completed MP4s', storage.exportBytes],
                  ['Temporary work', storage.temporaryBytes],
                  ['Project and retry inputs', storage.metadataBytes],
                ] as const
              ).map(([name, bytes]) => (
                <tr key={name}>
                  <th scope="row">{name}</th>
                  <td>{byteLabel(bytes)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p>{byteLabel(storage.availableBytes)} free on this device.</p>
          <p>
            Saved revision {storage.revision}: allow about{' '}
            {byteLabel(storage.exportEstimate.requiredBytes)} of free space for the next export,
            including temporary work and a safety margin. The MP4 itself is estimated at{' '}
            {byteLabel(storage.exportEstimate.outputBytes)}. Actual sizes vary.
          </p>
          {storage.availableBytes < storage.exportEstimate.requiredBytes && (
            <p role="status">Free more storage before exporting.</p>
          )}
          <p>
            Remove completed MP4s below to reclaim space. Originals, recording files and retry
            inputs are retained for recovery.
          </p>
        </>
      )}
      {error && <p role="alert">{error}</p>}
      <button disabled={loading} onClick={() => setRefresh((value) => value + 1)}>
        {loading ? 'Checking storage…' : 'Refresh storage'}
      </button>
    </details>
  );
}
