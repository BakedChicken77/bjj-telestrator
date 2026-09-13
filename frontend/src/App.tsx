import { ProjectVersions } from './components/ProjectVersions';
import { MediaPreparation } from './components/MediaPreparation';
import { useMediaPreparation } from './useMediaPreparation';
import { useCallback, useEffect, useRef, useState } from 'react';
import { api, type ExportJob, type ProjectSummary } from './api';
import { ProjectStorage } from './components/ProjectStorage';
import { ExportRecovery } from './components/ExportRecovery';
import { useEditor } from './store';
import type { Project, Tool } from './model';
import { VideoStage } from './components/VideoStage';
import { Timeline } from './components/Timeline';
import { Inspector } from './components/Inspector';
import { VoiceoverPanel } from './components/VoiceoverPanel';
import { useAutosave } from './useAutosave';
import { isNativeIOS, nativeAPI, nativeBridge } from './native';
import { SupportDialog } from './components/SupportDialog';
import { diagnosticSummary } from './project/diagnostics';

const tools: { id: Tool; label: string; glyph: string }[] = [
  { id: 'select', label: 'Select', glyph: '↖' },
  { id: 'line', label: 'Line', glyph: '╱' },
  { id: 'arrow', label: 'Arrow', glyph: '↗' },
  { id: 'ellipse', label: 'Ellipse', glyph: '○' },
  { id: 'rectangle', label: 'Rectangle', glyph: '□' },
  { id: 'freehand', label: 'Freehand', glyph: '' },
  { id: 'text', label: 'Text', glyph: 'T' },
];
const durationLabel = (sec: number) =>
  `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`;
const errorText = (cause: unknown) =>
  cause instanceof Error ? cause.message : 'Something went wrong. Please retry.';

function Toolbar() {
  const tool = useEditor((s) => s.tool);
  const recording = useEditor((s) => s.recording);
  const selectedId = useEditor((s) => s.selectedId);
  const canUndo = useEditor((s) => s.past.length > 0);
  const canRedo = useEditor((s) => s.future.length > 0);
  return (
    <nav className="annotation-toolbar" aria-label="Annotation tools" inert={recording}>
      <span className="toolbar-caption">ANNOTATE</span>
      <div className="tool-set">
        {tools.map((item) => (
          <button
            key={item.id}
            aria-label={item.label}
            aria-pressed={tool === item.id}
            className={`tool-button ${tool === item.id ? 'active' : ''}`}
            title={item.label}
            onClick={() => useEditor.getState().setTool(item.id)}
          >
            <span aria-hidden="true">
              {item.id === 'freehand' ? (
                <svg width="26" height="26" viewBox="0 0 26 26" fill="none">
                  <path
                    d="M3 18C5 9 10 4 12 7S6 20 11 20 17 6 21 8 20 17 23 13"
                    stroke="currentColor"
                    strokeWidth="1.8"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              ) : (
                item.glyph
              )}
            </span>
            <small>{item.label}</small>
          </button>
        ))}
      </div>
      <div className="toolbar-divider" />
      <button
        aria-label="Undo"
        title="Undo · Ctrl+Z"
        disabled={!canUndo}
        onClick={() => useEditor.getState().undo()}
      >
        ↶
      </button>
      <button
        aria-label="Redo"
        title="Redo · Ctrl+Y"
        disabled={!canRedo}
        onClick={() => useEditor.getState().redo()}
      >
        ↷
      </button>
      <button
        aria-label="Delete selected annotation"
        title="Delete selected annotation"
        disabled={!selectedId}
        onClick={() =>
          useEditor.getState().edit((p) => {
            p.annotations = p.annotations.filter((a) => a.id !== selectedId);
          })
        }
      >
        ⌫
      </button>
      <span className="toolbar-hint">Pause. Draw. Explain.</span>
    </nav>
  );
}

function ProjectName({ project }: { project: Project }) {
  const recording = useEditor((state) => state.recording);
  const [name, setName] = useState(project.projectName);
  useEffect(() => setName(project.projectName), [project.projectName]);
  return (
    <input
      aria-label="Project name"
      disabled={recording}
      className="project-name"
      value={name}
      maxLength={160}
      onChange={(e) => setName(e.target.value)}
      onBlur={() => {
        const value = name.trim();
        if (value)
          useEditor.getState().edit((draft) => {
            draft.projectName = value;
          });
        else setName(project.projectName);
      }}
      onKeyDown={(e) => {
        if (e.key === 'Enter') e.currentTarget.blur();
      }}
    />
  );
}

export default function App() {
  const nativeIOS = isNativeIOS();
  const project = useEditor((s) => s.project);
  const recording = useEditor((s) => s.recording);
  const editorError = useEditor((s) => s.error);
  const videoRef = useRef<HTMLVideoElement>(null);
  const [browserOpen, setBrowserOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [jobs, setJobs] = useState<ExportJob[]>([]);
  const [busy, setBusy] = useState<string | null>('Opening your workspace…');
  const [error, setError] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [storageTools, setStorageTools] = useState(false);
  const [recoveryTools, setRecoveryTools] = useState(false);
  const [mediaTools, setMediaTools] = useState(false);
  const [workspaceReady, setWorkspaceReady] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [mobilePanel, setMobilePanel] = useState<'timeline' | 'properties'>('timeline');
  const {
    status,
    error: saveError,
    flush,
    recovery,
    recoveryError,
    dismissRecovery,
    clearDraft,
  } = useAutosave();
  const [support, setSupport] = useState<string | null>(null);

  const loadProject = useCallback((next: Project) => {
    videoRef.current?.pause();
    useEditor.getState().setProject(next);
    localStorage.setItem('bjj:lastProject', next.projectId);
    setBrowserOpen(false);
    setError(null);
    setJobs([]);
  }, []);
  const media = useMediaPreparation({
    enabled: mediaTools && workspaceReady,
    flush,
    onLoad: loadProject,
    onBusy: setBusy,
    onError: setError,
    onNotice: setNotice,
  });

  useEffect(() => {
    let cancelled = false;
    async function start() {
      try {
        const capabilities = await api.capabilities();
        setMediaTools(!!(capabilities.mediaJobs && capabilities.proxyRepair));
        setRecoveryTools(
          !!(
            capabilities.projectCheckpoints &&
            capabilities.projectDuplicate &&
            capabilities.projectTrash
          ),
        );
        setStorageTools(
          !!(
            capabilities.exportRetry &&
            capabilities.storageBreakdown &&
            capabilities.exportFileCleanup
          ),
        );
        if (
          !capabilities.conditionalSave ||
          !capabilities.conditionalExport ||
          capabilities.schemaVersion < 2
        )
          throw new Error(
            'Upgrade required: the editor and local service need matching versions for safe saves.',
          );
        const list = await api.projects();
        if (cancelled) return;
        setProjects(list);
        const last = localStorage.getItem('bjj:lastProject');
        if (last && list.some((item) => item.projectId === last)) {
          const next = await api.project(last);
          if (!cancelled) loadProject(next);
        } else setBrowserOpen(true);
      } catch (cause) {
        if (!cancelled) {
          setError(errorText(cause));
          setBrowserOpen(true);
        }
      } finally {
        if (!cancelled) {
          setBusy(null);
          setWorkspaceReady(true);
        }
      }
    }
    void start();
    return () => {
      cancelled = true;
    };
  }, [loadProject]);

  useEffect(() => {
    if (!exportOpen || !project) return;
    let cancelled = false;
    const refresh = async () => {
      try {
        const result = await api.exports(project.projectId);
        if (!cancelled) setJobs(result);
      } catch (cause) {
        if (!cancelled) setError(errorText(cause));
      }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 1000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [exportOpen, project?.projectId]);

  const seek = useCallback((time: number) => {
    if (useEditor.getState().recording) return;
    const duration = useEditor.getState().project?.source.durationSec ?? 0;
    const next = Math.max(0, Math.min(duration, time));
    if (videoRef.current) videoRef.current.currentTime = next;
    useEditor.getState().setTime(next);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (
        target.closest('input, textarea, select, [contenteditable="true"]') ||
        browserOpen ||
        exportOpen
      )
        return;
      const state = useEditor.getState();
      if (!state.project) return;
      if (state.recording) {
        if (event.code === 'Space' || event.key.startsWith('Arrow') || event.key === 'Backspace')
          event.preventDefault();
        return;
      }
      const control = event.ctrlKey || event.metaKey;
      if (event.code === 'Space') {
        event.preventDefault();
        if (videoRef.current?.paused)
          void videoRef.current.play().catch((cause: unknown) => setError(errorText(cause)));
        else videoRef.current?.pause();
      } else if (control && event.key.toLowerCase() === 'z') {
        event.preventDefault();
        if (event.shiftKey) state.redo();
        else state.undo();
      } else if (control && event.key.toLowerCase() === 'y') {
        event.preventDefault();
        state.redo();
      } else if ((event.key === 'Delete' || event.key === 'Backspace') && state.selectedId) {
        event.preventDefault();
        state.edit((p) => {
          p.annotations = p.annotations.filter((a) => a.id !== state.selectedId);
        });
        state.select(null);
      } else if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        event.preventDefault();
        seek(
          state.currentTime +
            (event.key === 'ArrowLeft' ? -1 : 1) *
              (event.shiftKey
                ? state.project.settings.largeSeekStepSec
                : state.project.settings.seekStepSec),
        );
      } else if (event.key === 'Escape') {
        state.select(null);
        state.setTool('select');
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [browserOpen, exportOpen, seek]);

  async function showBrowser() {
    if (useEditor.getState().recording) return;
    try {
      await flush();
      setProjects(await api.projects());
      setBrowserOpen(true);
      videoRef.current?.pause();
    } catch (cause) {
      setError(errorText(cause));
    }
  }

  async function importFile(file: File | undefined) {
    if (!file) return;
    if (mediaTools) {
      await media.start(file);
      return;
    }
    setBusy('Importing video and preparing the editing proxy…');
    setError(null);
    try {
      await flush();
      loadProject(await api.importVideo(file));
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }

  async function importOnPhone(source: 'photos' | 'files') {
    if (mediaTools) {
      await media.start(undefined, source);
      return;
    }
    setBusy('Choosing and preparing your video…');
    setError(null);
    try {
      await flush();
      const next = await nativeAPI.importVideo(source);
      if (next) loadProject(next);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }

  async function startExport() {
    if (!project) return;
    setExporting(true);
    setError(null);
    try {
      const saved = await flush();
      if (!saved) return;
      const job = await api.export(saved.projectId, saved.revision);
      setJobs((list) => [job, ...list.filter((item) => item.jobId !== job.jobId)]);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setExporting(false);
    }
  }

  async function recoverCopy(draftProject: Project) {
    setBusy('Recovering an independent copy…');
    try {
      const copy = await api.recoverCopy(draftProject);
      loadProject(copy);
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      setBusy(null);
    }
  }
  const visibleError = error ?? saveError ?? recoveryError ?? editorError;
  return (
    <div className={`app-shell mobile-${mobilePanel}`}>
      <header className="app-topbar">
        <div className="brand">
          <svg viewBox="0 0 32 32" aria-hidden="true">
            <path
              d="M4 9 16 3 28 9 16 15ZM4 15l12 6 12-6M4 21l12 6 12-6"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.3"
              strokeLinejoin="round"
            />
          </svg>
          <span>
            BJJ <strong>TELESTRATOR</strong>
          </span>
        </div>
        <div className="topbar-divider" />
        {project ? (
          <ProjectName project={project} />
        ) : (
          <span className="project-name placeholder">Your coaching workspace</span>
        )}
        <div className="save-indicator" data-testid="save-status" role="status">
          <i className={status} />
          {status === 'saved'
            ? 'Saved'
            : status === 'pending'
              ? 'Unsaved changes'
              : status === 'saving'
                ? 'Saving…'
                : status === 'conflict'
                  ? 'Save conflict'
                  : 'Save failed'}
        </div>
        <div className="topbar-actions">
          <button onClick={() => void showBrowser()} aria-label="Projects" disabled={recording}>
            Projects
          </button>
          {project && (
            <button
              aria-label="Save now"
              title="Save now"
              onClick={() => void flush().catch((cause: unknown) => setError(errorText(cause)))}
            >
              {status === 'failed' ? 'Retry save' : 'Save'}
            </button>
          )}
          <button
            className="primary"
            disabled={!project || recording}
            aria-label="Export video"
            onClick={() => {
              setExportOpen(true);
              videoRef.current?.pause();
            }}
          >
            Export MP4 <span aria-hidden="true">↗</span>
          </button>
        </div>
      </header>
      {notice && (
        <p className="recovery-notice" role="status">
          {notice}
        </p>
      )}
      {support !== null && <SupportDialog text={support} onClose={() => setSupport(null)} />}
      {project && status === 'conflict' && (
        <section className="recovery-banner" aria-label="Save conflict recovery">
          <p>Your edits and the newer saved version have been kept separately.</p>
          <button disabled={!!busy} onClick={() => void recoverCopy(project)}>
            Recover my edits as a copy
          </button>
          <button
            disabled={!!busy}
            onClick={() =>
              void api
                .project(project.projectId)
                .then(loadProject)
                .catch((cause: unknown) => setError(errorText(cause)))
            }
          >
            Reload saved version
          </button>
        </section>
      )}
      {recovery.length > 0 && (
        <section className="recovery-banner" aria-label="Pending recovery drafts">
          <p>Unsaved edits were found. Recover a separate copy to keep both versions.</p>
          {recovery.map((draft) => (
            <div key={draft.draftId}>
              <span>
                {new Date(draft.savedAt).toLocaleString()} · {draft.project.annotations.length}{' '}
                annotations{' '}
              </span>
              <button disabled={!!busy} onClick={() => void recoverCopy(draft.project)}>
                Recover draft as a copy
              </button>
              <button
                onClick={() =>
                  void clearDraft(draft)
                    .then(dismissRecovery)
                    .catch((cause: unknown) => setError(errorText(cause)))
                }
              >
                Discard this draft
              </button>
            </div>
          ))}
          <button onClick={dismissRecovery}>Use saved version; keep drafts</button>
        </section>
      )}
      {visibleError && (
        <div className="error-banner" role="alert">
          <span>{visibleError}</span>
          <button onClick={() => setSupport(diagnosticSummary(nativeIOS ? 'ios' : 'desktop'))}>
            Inspect support summary
          </button>
          <button
            aria-label="Dismiss error"
            onClick={() => {
              setError(null);
              useEditor.getState().setError(null);
            }}
          >
            ×
          </button>
        </div>
      )}
      {project ? (
        <>
          <Toolbar />
          <main className="workspace">
            <div className="editing-column">
              <VideoStage videoRef={videoRef} onSeek={seek} />
              <nav className="mobile-panel-tabs" aria-label="Editing panels" inert={recording}>
                <button
                  aria-pressed={mobilePanel === 'timeline'}
                  onClick={() => setMobilePanel('timeline')}
                >
                  Timeline
                </button>
                <button
                  aria-pressed={mobilePanel === 'properties'}
                  onClick={() => setMobilePanel('properties')}
                >
                  Properties & settings
                </button>
              </nav>
              <VoiceoverPanel videoRef={videoRef} onSeek={seek} />
              <div className="timeline-lock-region" inert={recording}>
                <Timeline onSeek={seek} />
              </div>
            </div>
            <div className="inspector-lock-region" inert={recording}>
              <Inspector />
            </div>
          </main>
          <footer className="statusbar">
            <span>
              <i className="local-dot" /> LOCAL WORKSPACE
            </span>
            <span>
              {project.source.displayWidth} × {project.source.displayHeight} ·{' '}
              {project.source.avgFrameRate.toFixed(2)} fps · {project.annotations.length}{' '}
              annotations
            </span>
            <span>
              <kbd>Space</kbd> Play / Pause <kbd>Ctrl Z</kbd> Undo <kbd>← →</kbd> Seek
            </span>
          </footer>
        </>
      ) : (
        <main className="welcome-background">
          <div className="welcome-mark">↗</div>
          <p>Every detail changes the game.</p>
          <button className="primary" onClick={() => setBrowserOpen(true)}>
            Open your workspace
          </button>
        </main>
      )}

      {browserOpen && (
        <div className="modal-backdrop">
          <section
            className="modal project-browser"
            role="dialog"
            aria-modal="true"
            aria-labelledby="project-browser-title"
          >
            <div className="modal-heading">
              <div>
                <p className="eyebrow">YOUR WORKSPACE</p>
                <h1 id="project-browser-title">Review the details.</h1>
                <p>Turn your rolling footage into clear, visual coaching.</p>
              </div>
              {project && (
                <button
                  className="close-button"
                  aria-label="Close projects"
                  disabled={!!busy}
                  onClick={() => setBrowserOpen(false)}
                >
                  ×
                </button>
              )}
            </div>
            {nativeIOS ? (
              <div className="native-import">
                <strong>Import a rolling video</strong>
                <p>Videos and projects stay on this iPhone.</p>
                <div>
                  <button
                    className="primary"
                    disabled={Boolean(busy)}
                    onClick={() => void importOnPhone('photos')}
                  >
                    Choose from Photos
                  </button>
                  <button disabled={Boolean(busy)} onClick={() => void importOnPhone('files')}>
                    Choose from Files
                  </button>
                </div>
                <small>MP4, MOV and iPhone H.264 / HEVC videos</small>
              </div>
            ) : (
              <label className={`upload-zone ${busy ? 'disabled' : ''}`}>
                <span className="upload-icon">↑</span>
                <strong>Import a rolling video</strong>
                <span>MP4, MOV, HEVC, WebM and more</span>
                <small>Your footage stays on this computer.</small>
                <input
                  aria-label="Import video"
                  type="file"
                  accept="video/*,.mov,.mkv,.avi,.m4v,.mts,.m2ts"
                  disabled={Boolean(busy)}
                  onChange={(e) => {
                    void importFile(e.target.files?.[0]);
                    e.target.value = '';
                  }}
                />
              </label>
            )}
            <div className="section-heading">
              <h2>Recent projects</h2>
              <button
                className="text-button"
                disabled={Boolean(busy)}
                onClick={() =>
                  void api
                    .projects()
                    .then(setProjects)
                    .catch((cause: unknown) => setError(errorText(cause)))
                }
              >
                Refresh
              </button>
            </div>
            {recoveryTools && (
              <ProjectVersions
                project={project}
                projects={projects}
                busy={!!busy}
                flush={flush}
                onBusy={setBusy}
                onLoad={loadProject}
                onNotice={setNotice}
              />
            )}
            {mediaTools && project && (
              <div className="preview-repair">
                <button
                  disabled={!!busy || recording}
                  onClick={() => void media.start(undefined, undefined, true)}
                >
                  Repair preview
                </button>
                <small>
                  Regenerate this review’s preview from its original, preserving drawings and
                  narration.
                </small>
              </div>
            )}
            <div className="project-list">
              {projects.length === 0 ? (
                <div className="empty-projects">
                  Your projects will appear here after importing a video.
                </div>
              ) : (
                projects.map((item) => (
                  <div className="project-card" key={item.projectId}>
                    <button
                      className="project-open"
                      disabled={Boolean(busy)}
                      onClick={async () => {
                        setBusy('Opening project…');
                        try {
                          await flush();
                          loadProject(await api.project(item.projectId));
                        } catch (cause) {
                          setError(errorText(cause));
                        } finally {
                          setBusy(null);
                        }
                      }}
                    >
                      <div className="project-thumbnail">▶</div>
                      <div>
                        <strong>{item.projectName}</strong>
                        <span>
                          {durationLabel(item.durationSec)} · {item.annotationCount} annotations ·{' '}
                          {new Date(item.updatedAt).toLocaleDateString()}
                        </span>
                      </div>
                      <span className="open-arrow">↗</span>
                    </button>
                    <button
                      className="delete-project"
                      aria-label={`Delete project ${item.projectName}`}
                      title="Move to Recently deleted"
                      disabled={Boolean(busy) || !recoveryTools || !!item.unavailableCode}
                      onClick={async () => {
                        if (
                          !window.confirm(
                            `Move “${item.projectName}” to Recently deleted? Its video, recordings, checkpoints and exports will be kept until permanent deletion.`,
                          )
                        )
                          return;
                        setBusy('Moving project to Recently deleted…');
                        try {
                          const saved = await flush();
                          const revision =
                            saved?.projectId === item.projectId ? saved.revision : item.revision;
                          if (revision === undefined)
                            throw new Error(
                              'Refresh the project list before deleting this project.',
                            );
                          await api.deleteProject(item.projectId, revision);
                          setProjects((list) =>
                            list.filter((entry) => entry.projectId !== item.projectId),
                          );
                          if (project?.projectId === item.projectId) {
                            useEditor.getState().setProject(null);
                            localStorage.removeItem('bjj:lastProject');
                          }
                          setNotice(
                            'Project moved to Recently deleted. Its files are still recoverable.',
                          );
                        } catch (cause) {
                          setError(errorText(cause));
                        } finally {
                          setBusy(null);
                        }
                      }}
                    >
                      ×
                    </button>
                  </div>
                ))
              )}
            </div>
            {media.job && (
              <MediaPreparation
                job={media.job}
                error={media.statusError}
                onCancel={() => void media.cancel()}
                onDismiss={media.dismiss}
              />
            )}
            {busy && !media.job && (
              <div className="import-status" role="status">
                <span className="spinner" />
                {busy}
                <small>
                  Long videos may take a few minutes. Keep {nativeIOS ? 'the app' : 'this tab'}{' '}
                  open.
                </small>
              </div>
            )}
            {visibleError && (
              <p className="dialog-error" role="alert">
                {visibleError}
              </p>
            )}
          </section>
        </div>
      )}

      {exportOpen && project && (
        <div className="modal-backdrop">
          <section
            className="modal export-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="export-title"
          >
            <div className="modal-heading">
              <div>
                <p className="eyebrow">READY TO SHARE</p>
                <h1 id="export-title">Export your review.</h1>
                <p>One ordinary MP4, with every annotation in the picture.</p>
              </div>
              <button
                className="close-button"
                aria-label="Close exports"
                onClick={() => setExportOpen(false)}
              >
                ×
              </button>
            </div>
            <div className="export-spec">
              <span>MP4 / H.264 + AAC</span>
              <span>
                {project.source.displayWidth} × {project.source.displayHeight}
              </span>
              <span>{durationLabel(project.source.durationSec)}</span>
            </div>
            <div className="export-options">
              <label>
                Frame rate
                <input
                  aria-label="Export frame rate"
                  type="number"
                  min={1}
                  max={nativeIOS ? 60 : 120}
                  value={project.exportSettings.fps}
                  onChange={(e) => {
                    const value = Number(e.target.value);
                    if (value > 0 && value <= (nativeIOS ? 60 : 120))
                      useEditor.getState().edit((p) => {
                        p.exportSettings.fps = value;
                      });
                  }}
                />
              </label>
              <label>
                Quality
                <select
                  aria-label="Export quality"
                  value={project.exportSettings.crf}
                  onChange={(e) =>
                    useEditor.getState().edit((p) => {
                      p.exportSettings.crf = Number(e.target.value);
                    })
                  }
                >
                  <option value={18}>{nativeIOS ? 'High quality' : 'High · CRF 18'}</option>
                  <option value={23}>{nativeIOS ? 'Balanced' : 'Balanced · CRF 23'}</option>
                  <option value={28}>{nativeIOS ? 'Smaller file' : 'Smaller file · CRF 28'}</option>
                </select>
              </label>
              {!nativeIOS && (
                <label>
                  Encoding speed
                  <select
                    aria-label="Encoding speed"
                    value={project.exportSettings.preset}
                    onChange={(e) =>
                      useEditor.getState().edit((p) => {
                        p.exportSettings.preset = e.target
                          .value as Project['exportSettings']['preset'];
                      })
                    }
                  >
                    <option value="veryfast">Fast</option>
                    <option value="medium">Balanced</option>
                    <option value="slow">Compact</option>
                  </select>
                </label>
              )}
            </div>
            <button
              className="primary export-start"
              disabled={exporting}
              onClick={() => void startExport()}
            >
              {exporting ? 'Starting export…' : 'Render MP4'}
            </button>
            <div className="section-heading">
              <h2>Exports</h2>
              <span>
                {nativeIOS
                  ? 'Keep the app open during rendering'
                  : 'Rendering continues while you edit'}
              </span>
            </div>
            <div className="export-list">
              {jobs.length === 0 ? (
                <p className="empty-projects">Your rendered reviews will appear here.</p>
              ) : (
                jobs.map((job) => (
                  <article className="export-job" key={job.jobId}>
                    <div className="job-heading">
                      <strong>
                        {job.filename ?? `Review · ${new Date(job.createdAt).toLocaleTimeString()}`}
                      </strong>
                      <span className={`job-state ${job.status}`}>{job.status}</span>
                    </div>
                    {(job.status === 'running' || job.status === 'queued') && (
                      <>
                        <progress max={100} value={job.progress} aria-label="Export progress" />
                        <div className="job-details">
                          <span>
                            {Math.round(job.progress)}% · {durationLabel(job.renderedSec)} rendered
                          </span>
                          <button
                            onClick={() =>
                              void api
                                .cancelExport(job.jobId)
                                .then((next) =>
                                  setJobs((list) =>
                                    list.map((item) => (item.jobId === next.jobId ? next : item)),
                                  ),
                                )
                                .catch((cause: unknown) => setError(errorText(cause)))
                            }
                          >
                            Cancel export
                          </button>
                        </div>
                      </>
                    )}
                    {job.status === 'completed' &&
                      job.outputAvailable !== false &&
                      (nativeIOS ? (
                        <button
                          className="download-button"
                          onClick={() =>
                            void nativeBridge
                              .shareExport({ jobId: job.jobId })
                              .catch((cause: unknown) => setError(errorText(cause)))
                          }
                        >
                          Save or share MP4 ↗
                        </button>
                      ) : (
                        <a
                          className="download-button"
                          href={`/api/exports/${job.jobId}/download`}
                          download={job.filename ?? undefined}
                        >
                          Download MP4 ↓
                        </a>
                      ))}
                    {job.error && <p className="dialog-error">{job.error}</p>}
                    {storageTools && (
                      <ExportRecovery
                        job={job}
                        revision={project.revision}
                        dirty={status !== 'saved'}
                        onJob={(next) =>
                          setJobs((list) => [
                            next,
                            ...list.filter((item) => item.jobId !== next.jobId),
                          ])
                        }
                        onError={(cause) => setError(errorText(cause))}
                      />
                    )}
                  </article>
                ))
              )}
            </div>
            {storageTools && (
              <ProjectStorage
                projectId={project.projectId}
                revision={project.revision}
                outputs={jobs
                  .map((job) => `${job.jobId}:${job.status}:${String(job.outputAvailable)}`)
                  .join(',')}
              />
            )}
            {visibleError && (
              <p className="dialog-error" role="alert">
                {visibleError}
              </p>
            )}
          </section>
        </div>
      )}
      {media.job && !browserOpen && (
        <div className="media-preparation-toast">
          <MediaPreparation
            job={media.job}
            error={media.statusError}
            onCancel={() => void media.cancel()}
            onDismiss={media.dismiss}
          />
        </div>
      )}
      {busy && !browserOpen && !media.job && (
        <div className="loading-toast" role="status">
          <span className="spinner" />
          {busy}
        </div>
      )}
    </div>
  );
}
