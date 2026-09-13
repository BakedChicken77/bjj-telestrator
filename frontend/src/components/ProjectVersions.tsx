import { useEffect, useState } from 'react';
import { api, type Checkpoint, type DeletedProject, type ProjectSummary } from '../api';
import type { Project } from '../model';

export function ProjectVersions({
  project,
  projects,
  busy,
  flush,
  onBusy,
  onLoad,
  onNotice,
}: {
  project: Project | null;
  projects: ProjectSummary[];
  busy: boolean;
  flush: () => Promise<Project | null>;
  onBusy: (message: string | null) => void;
  onLoad: (project: Project) => void;
  onNotice: (message: string) => void;
}) {
  const [checkpoints, setCheckpoints] = useState<Checkpoint[]>([]);
  const [deleted, setDeleted] = useState<DeletedProject[]>([]);
  const [label, setLabel] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    void Promise.all([project ? api.checkpoints(project.projectId) : [], api.deletedProjects()])
      .then(([versions, trash]) => {
        if (!cancelled) {
          setCheckpoints(versions);
          setDeleted(trash);
        }
      })
      .catch((cause: unknown) => {
        if (!cancelled)
          setError(cause instanceof Error ? cause.message : 'Recovery records could not be read.');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [project?.projectId, projects, refresh]);

  async function run(message: string, action: (saved: Project | null) => Promise<void>) {
    onBusy(message);
    setError(null);
    try {
      await action(await flush());
      setRefresh((value) => value + 1);
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : 'Recovery failed. Your existing files were preserved.',
      );
    } finally {
      onBusy(null);
    }
  }

  return (
    <section className="project-versions" aria-label="Project recovery">
      {project && (
        <details>
          <summary>Checkpoints and copies · {project.projectName}</summary>
          <p>
            A checkpoint keeps this saved review and its media references. Restoring first preserves
            your current edits as another checkpoint, then starts a fresh undo history.
          </p>
          <fieldset disabled={busy || loading}>
            <legend>Save a version</legend>
            <label>
              Checkpoint label{' '}
              <input
                value={label}
                maxLength={120}
                onChange={(event) => setLabel(event.target.value)}
              />
            </label>
            <button
              disabled={!label.trim()}
              onClick={() =>
                void run('Saving a verified checkpoint…', async (saved) => {
                  if (!saved || saved.projectId !== project.projectId) return;
                  await api.createCheckpoint(saved.projectId, saved.revision, label.trim());
                  setLabel('');
                  onNotice('Checkpoint saved.');
                })
              }
            >
              Save checkpoint
            </button>
            <button
              onClick={() =>
                void run('Copying and verifying project media…', async (saved) => {
                  if (!saved || saved.projectId !== project.projectId) return;
                  onLoad(await api.duplicateProject(saved.projectId, saved.revision));
                  onNotice(
                    'Opened an independent copy of the saved review. Earlier checkpoints and exports remain with the original.',
                  );
                })
              }
            >
              Duplicate project
            </button>
          </fieldset>
          {!loading && !error && checkpoints.length === 0 && <p>No saved checkpoints yet.</p>}
          <ul>
            {checkpoints.map((item) => (
              <li key={item.checkpointId}>
                <span>
                  <strong>{item.label}</strong> · revision {item.revision} ·{' '}
                  {new Date(item.createdAt).toLocaleString()}
                </span>
                <button
                  disabled={busy}
                  onClick={() => {
                    if (
                      !window.confirm(
                        `Restore “${item.label}”? Your current review will be saved as a checkpoint before it is replaced.`,
                      )
                    )
                      return;
                    void run('Verifying and restoring the checkpoint…', async (saved) => {
                      if (!saved || saved.projectId !== project.projectId) return;
                      onLoad(
                        await api.restoreCheckpoint(
                          saved.projectId,
                          item.checkpointId,
                          saved.revision,
                        ),
                      );
                      onNotice(
                        'Checkpoint restored. Your previous review is available under Checkpoints and copies.',
                      );
                    });
                  }}
                >
                  Restore checkpoint {item.label}
                </button>
              </li>
            ))}
          </ul>
        </details>
      )}
      <details>
        <summary>Recently deleted{!loading && !error ? ` · ${deleted.length}` : ''}</summary>
        <p>
          Deleted projects keep their media, checkpoints and exports on this device. They use
          storage until you permanently delete them. There is no automatic expiry.
        </p>
        {!loading && !error && deleted.length === 0 && <p>No recently deleted projects.</p>}
        <ul>
          {deleted.map((item) => (
            <li key={item.trashId}>
              <span>
                <strong>{item.projectName}</strong> · {new Date(item.deletedAt).toLocaleString()}
              </span>
              <button
                disabled={busy}
                onClick={() =>
                  void run('Verifying and restoring project files…', async () => {
                    const result = await api.restoreDeletedProject(item.trashId);
                    onLoad(result.project);
                    onNotice(
                      result.copied
                        ? 'That project ID already exists. Opened an independent copy; the complete deleted project remains in Recently deleted.'
                        : 'Project restored with its checkpoints and exports.',
                    );
                  })
                }
              >
                Restore project {item.projectName}
              </button>
              <button
                disabled={busy}
                onClick={() => {
                  if (
                    !window.confirm(
                      `Permanently delete “${item.projectName}” and its original video, recordings, checkpoints and exports? This cannot be undone.`,
                    )
                  )
                    return;
                  void run('Permanently removing the deleted project…', async () => {
                    await api.permanentlyDeleteProject(item.trashId);
                    onNotice('Deleted project permanently removed.');
                  });
                }}
              >
                Permanently delete {item.projectName}
              </button>
            </li>
          ))}
        </ul>
      </details>
      {loading && <p role="status">Reading recovery records…</p>}
      {error && <p role="alert">{error}</p>}
      {error && (
        <button disabled={busy} onClick={() => setRefresh((value) => value + 1)}>
          Retry reading recovery records
        </button>
      )}
    </section>
  );
}
