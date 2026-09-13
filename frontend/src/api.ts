import { projectSchema, readProject, voiceoverSchema, type Project } from './model';
import { isNativeIOS, nativeAPI } from './native';
import { ProjectError } from './project/migrations';
import { recordDiagnostic } from './project/diagnostics';

export interface ProjectSummary {
  projectId: string;
  projectName: string;
  updatedAt: string;
  durationSec: number;
  annotationCount: number;
  unavailableCode?: string;
  revision?: number;
}
export interface MediaJob {
  jobId: string;
  projectId: string;
  operation: 'import' | 'repair';
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';
  stage: 'copying' | 'inspecting' | 'preparing_preview' | 'validating' | 'ready';
  progress: number | null;
  copiedBytes: number;
  totalBytes?: number | null;
  cancelRequested: boolean;
  errorCode?: string | null;
  error?: string | null;
  projectRevision?: number | null;
  createdAt: string;
}
export interface ExportJob {
  jobId: string;
  projectId: string;
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';
  progress: number;
  renderedSec: number;
  error: string | null;
  filename: string | null;
  createdAt: string;
  projectRevision?: number;
  retryOf?: string | null;
  retryAvailable?: boolean;
  outputAvailable?: boolean;
  errorCode?: string | null;
}
export interface SpaceEstimate {
  operation: string;
  incomingBytes: number;
  outputBytes: number;
  workingBytes: number;
  safetyBytes: number;
  requiredBytes: number;
}
export interface ProjectStorage {
  projectId: string;
  revision: number;
  sourceBytes: number;
  proxyBytes: number;
  recordingBytes: number;
  exportBytes: number;
  temporaryBytes: number;
  metadataBytes: number;
  totalBytes: number;
  availableBytes: number;
  exportEstimate: SpaceEstimate;
  recordingsRetained: boolean;
}
export interface Checkpoint {
  checkpointId: string;
  projectId: string;
  revision: number;
  label: string;
  createdAt: string;
}
export interface DeletedProject {
  trashId: string;
  projectId: string;
  projectName: string;
  revision: number;
  deletedAt: string;
}
export interface RestoredProject {
  project: Project;
  copied: boolean;
}
export interface RuntimeCapabilities {
  schemaVersion: number;
  requiredCapabilities: string[];
  conditionalSave: boolean;
  conditionalExport: boolean;
  recoveryCopy: boolean;
  exportRetry?: boolean;
  storageBreakdown?: boolean;
  exportFileCleanup?: boolean;
  projectCheckpoints?: boolean;
  projectDuplicate?: boolean;
  projectTrash?: boolean;
  mediaJobs?: boolean;
  proxyRepair?: boolean;
  hdrToSdr?: boolean;
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, init);
  } catch {
    if (init?.signal?.aborted)
      throw new ProjectError('JOB_CANCELLED', 'Video preparation was cancelled.');
    recordDiagnostic('CONNECTION_UNAVAILABLE');
    throw new ProjectError(
      'CONNECTION_UNAVAILABLE',
      'Cannot connect to BJJ Telestrator. Check that the local backend is running, then retry.',
    );
  }
  if (!response.ok) {
    let message = `Request failed (${response.status}).`;
    let code = 'REQUEST_FAILED';
    try {
      const error: { detail?: unknown; code?: string } = await response.json();
      if (typeof error.code === 'string') code = error.code;
      if (typeof error.detail === 'string') message = error.detail;
      else if (Array.isArray(error.detail))
        message = error.detail
          .map((item: unknown) =>
            typeof item === 'object' && item !== null && 'msg' in item
              ? String(item.msg)
              : 'Invalid project data',
          )
          .join('; ');
    } catch {
      /* The status above remains useful for non-JSON server errors. */
    }
    recordDiagnostic(code);
    throw new ProjectError(code, message);
  }
  return response.status === 204 ? (undefined as T) : (response.json() as Promise<T>);
}

const desktopAPI = {
  createImportJob: () => request<MediaJob>('/api/import-jobs', { method: 'POST' }),
  mediaJob: (jobId: string) => request<MediaJob>(`/api/media-jobs/${jobId}`),
  cancelMediaJob: (jobId: string) =>
    request<MediaJob>(`/api/media-jobs/${jobId}`, { method: 'DELETE' }),
  repairProxy: (projectId: string, revision: number) =>
    request<MediaJob>(`/api/projects/${projectId}/proxy-jobs`, {
      method: 'POST',
      headers: { 'If-Match': `"${revision}"` },
    }),
  capabilities: () => request<RuntimeCapabilities>('/api/capabilities'),
  recoverCopy: async (project: Project) =>
    readProject(
      await request<unknown>(`/api/projects/${project.projectId}/recover-copy`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(projectSchema.parse(project)),
      }),
    ),
  uploadVoiceover: async (
    projectId: string,
    recording: Blob,
    startSec: number,
    extension: string,
  ) => {
    const form = new FormData();
    form.append('file', recording, `voiceover.${extension}`);
    form.append('startSec', String(startSec));
    return voiceoverSchema.parse(
      await request<unknown>(`/api/projects/${projectId}/voiceovers`, {
        method: 'POST',
        body: form,
      }),
    );
  },
  projects: () => request<ProjectSummary[]>('/api/projects'),
  project: async (id: string) => readProject(await request<unknown>(`/api/projects/${id}`)),
  importVideo: async (
    file: File,
    name?: string,
    options?: { jobId: string; signal?: AbortSignal },
  ) => {
    const form = new FormData();
    form.append('file', file);
    if (name) form.append('name', name);
    return projectSchema.parse(
      await request<unknown>('/api/projects/import', {
        method: 'POST',
        body: form,
        headers: options ? { 'X-BJJ-Import-ID': options.jobId } : undefined,
        signal: options?.signal,
      }),
    );
  },
  save: async (project: Project) =>
    projectSchema.parse(
      await request<unknown>(`/api/projects/${project.projectId}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json', 'If-Match': `"${project.revision}"` },
        body: JSON.stringify(projectSchema.parse(project)),
      }),
    ),
  deleteProject: (id: string, revision: number) =>
    request<void>(`/api/projects/${id}`, {
      method: 'DELETE',
      headers: { 'If-Match': `"${revision}"` },
    }),
  duplicateProject: async (id: string, revision: number) =>
    readProject(
      await request<unknown>(`/api/projects/${id}/duplicate`, {
        method: 'POST',
        headers: { 'If-Match': `"${revision}"` },
      }),
    ),
  checkpoints: (id: string) => request<Checkpoint[]>(`/api/projects/${id}/checkpoints`),
  createCheckpoint: (id: string, revision: number, label: string) =>
    request<Checkpoint>(`/api/projects/${id}/checkpoints`, {
      method: 'POST',
      headers: { 'If-Match': `"${revision}"`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ label }),
    }),
  restoreCheckpoint: async (id: string, checkpointId: string, revision: number) =>
    readProject(
      await request<unknown>(`/api/projects/${id}/checkpoints/${checkpointId}/restore`, {
        method: 'POST',
        headers: { 'If-Match': `"${revision}"` },
      }),
    ),
  deletedProjects: () => request<DeletedProject[]>('/api/recently-deleted'),
  restoreDeletedProject: async (trashId: string): Promise<RestoredProject> => {
    const result = await request<{ project: unknown; copied: boolean }>(
      `/api/recently-deleted/${trashId}/restore`,
      { method: 'POST' },
    );
    return { ...result, project: readProject(result.project) };
  },
  permanentlyDeleteProject: (trashId: string) =>
    request<void>(`/api/recently-deleted/${trashId}`, { method: 'DELETE' }),
  exports: (id: string) => request<ExportJob[]>(`/api/projects/${id}/exports`),
  export: (id: string, revision: number) =>
    request<ExportJob>(`/api/projects/${id}/exports`, {
      method: 'POST',
      headers: { 'If-Match': `"${revision}"` },
    }),
  exportJob: (id: string) => request<ExportJob>(`/api/exports/${id}`),
  cancelExport: (id: string) => request<ExportJob>(`/api/exports/${id}/cancel`, { method: 'POST' }),
  retryExport: (id: string) => request<ExportJob>(`/api/exports/${id}/retry`, { method: 'POST' }),
  removeExportFile: (id: string) =>
    request<ExportJob>(`/api/exports/${id}/file`, { method: 'DELETE' }),
  storage: (id: string) => request<ProjectStorage>(`/api/projects/${id}/storage`),
};

/** Keep the verified desktop HTTP path; iOS uses an entirely local native service. */
export const api = {
  ...desktopAPI,
  createImportJob: () =>
    isNativeIOS() ? nativeAPI.createImportJob() : desktopAPI.createImportJob(),
  mediaJob: (id: string) => (isNativeIOS() ? nativeAPI.mediaJob(id) : desktopAPI.mediaJob(id)),
  cancelMediaJob: (id: string) =>
    isNativeIOS() ? nativeAPI.cancelMediaJob(id) : desktopAPI.cancelMediaJob(id),
  repairProxy: (id: string, revision: number) =>
    isNativeIOS() ? nativeAPI.repairProxy(id, revision) : desktopAPI.repairProxy(id, revision),
  capabilities: () => (isNativeIOS() ? nativeAPI.capabilities() : desktopAPI.capabilities()),
  recoverCopy: (project: Project) =>
    isNativeIOS() ? nativeAPI.recoverCopy(project) : desktopAPI.recoverCopy(project),
  projects: () => (isNativeIOS() ? nativeAPI.projects() : desktopAPI.projects()),
  project: (id: string) => (isNativeIOS() ? nativeAPI.project(id) : desktopAPI.project(id)),
  save: (project: Project) => (isNativeIOS() ? nativeAPI.save(project) : desktopAPI.save(project)),
  deleteProject: (id: string, revision: number) =>
    isNativeIOS() ? nativeAPI.deleteProject(id, revision) : desktopAPI.deleteProject(id, revision),
  duplicateProject: (id: string, revision: number) =>
    isNativeIOS()
      ? nativeAPI.duplicateProject(id, revision)
      : desktopAPI.duplicateProject(id, revision),
  checkpoints: (id: string) =>
    isNativeIOS() ? nativeAPI.checkpoints(id) : desktopAPI.checkpoints(id),
  createCheckpoint: (id: string, revision: number, label: string) =>
    isNativeIOS()
      ? nativeAPI.createCheckpoint(id, revision, label)
      : desktopAPI.createCheckpoint(id, revision, label),
  restoreCheckpoint: (id: string, checkpointId: string, revision: number) =>
    isNativeIOS()
      ? nativeAPI.restoreCheckpoint(id, checkpointId, revision)
      : desktopAPI.restoreCheckpoint(id, checkpointId, revision),
  deletedProjects: () =>
    isNativeIOS() ? nativeAPI.deletedProjects() : desktopAPI.deletedProjects(),
  restoreDeletedProject: (id: string) =>
    isNativeIOS() ? nativeAPI.restoreDeletedProject(id) : desktopAPI.restoreDeletedProject(id),
  permanentlyDeleteProject: (id: string) =>
    isNativeIOS()
      ? nativeAPI.permanentlyDeleteProject(id)
      : desktopAPI.permanentlyDeleteProject(id),
  exports: (id: string) => (isNativeIOS() ? nativeAPI.exports(id) : desktopAPI.exports(id)),
  export: (id: string, revision: number) =>
    isNativeIOS() ? nativeAPI.export(id, revision) : desktopAPI.export(id, revision),
  exportJob: (id: string) => (isNativeIOS() ? nativeAPI.exportJob(id) : desktopAPI.exportJob(id)),
  cancelExport: (id: string) =>
    isNativeIOS() ? nativeAPI.cancelExport(id) : desktopAPI.cancelExport(id),
  retryExport: (id: string) =>
    isNativeIOS() ? nativeAPI.retryExport(id) : desktopAPI.retryExport(id),
  removeExportFile: (id: string) =>
    isNativeIOS() ? nativeAPI.removeExportFile(id) : desktopAPI.removeExportFile(id),
  storage: (id: string) => (isNativeIOS() ? nativeAPI.storage(id) : desktopAPI.storage(id)),
};
