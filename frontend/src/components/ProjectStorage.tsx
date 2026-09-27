import { useEffect, useState } from 'react';
import { api, type ProjectStorage as Storage } from '../api';
import type { Project } from '../model';

export function byteLabel(value: number) {
  if (value < 1024) return `${value} B`;
  const unit = Math.min(3, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** unit).toFixed(1)} ${['B', 'KiB', 'MiB', 'GiB'][unit]}`;
}

export function ProjectStorage({
  projectId,
  revision,
  outputs,
  flush,
}: {
  projectId: string;
  revision: number;
  outputs: string;
  flush: () => Promise<Project | null>;
}) {
  const [storage, setStorage] = useState<Storage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  const [cleaning, setCleaning] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  async function cleanup() {
    setCleaning(true);
    setError(null);
    try {
      const saved = await flush();
      if (!saved || saved.projectId !== projectId)
        throw new Error('Open this project before cleaning previews.');
      const result = await api.cleanupPreviews(projectId, saved.revision);
      setNotice(`Removed ${result.files} obsolete preview files (${byteLabel(result.bytes)}).`);
      setRefresh((value) => value + 1);
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Preview cleanup could not finish. Refresh storage.',
      );
    } finally {
      setCleaning(false);
    }
  }
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
      {storage?.derivedCleanup && (
        <>
          <p>
            {byteLabel(storage.derivedCleanup.bytes)} in obsolete previews can be removed. Current
            previews and retained recovery references are protected; unused generated previews have
            a 24-hour grace period. Originals and recording files are retained.
          </p>
          <button
            disabled={cleaning || loading || !storage.derivedCleanup.files}
            onClick={() => void cleanup()}
          >
            {cleaning ? 'Cleaning previews…' : 'Clean obsolete previews'}
          </button>
        </>
      )}
      {storage?.cleanupBlocked && <p>{storage.cleanupBlocked}</p>}
      {notice && <p role="status">{notice}</p>}
      <button disabled={loading} onClick={() => setRefresh((value) => value + 1)}>
        {loading ? 'Checking storage…' : 'Refresh storage'}
      </button>
    </details>
  );
}
