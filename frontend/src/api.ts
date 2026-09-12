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
export interface RuntimeCapabilities {
  schemaVersion: number;
  requiredCapabilities: string[];
  conditionalSave: boolean;
  conditionalExport: boolean;
  recoveryCopy: boolean;
  exportRetry?: boolean;
  storageBreakdown?: boolean;
  exportFileCleanup?: boolean;
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, init);
  } catch {
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
  importVideo: async (file: File, name?: string) => {
    const form = new FormData();
    form.append('file', file);
    if (name) form.append('name', name);
    return projectSchema.parse(
      await request<unknown>('/api/projects/import', { method: 'POST', body: form }),
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
  deleteProject: (id: string) => request<void>(`/api/projects/${id}`, { method: 'DELETE' }),
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
  capabilities: () => (isNativeIOS() ? nativeAPI.capabilities() : desktopAPI.capabilities()),
  recoverCopy: (project: Project) =>
    isNativeIOS() ? nativeAPI.recoverCopy(project) : desktopAPI.recoverCopy(project),
  projects: () => (isNativeIOS() ? nativeAPI.projects() : desktopAPI.projects()),
  project: (id: string) => (isNativeIOS() ? nativeAPI.project(id) : desktopAPI.project(id)),
  save: (project: Project) => (isNativeIOS() ? nativeAPI.save(project) : desktopAPI.save(project)),
  deleteProject: (id: string) =>
    isNativeIOS() ? nativeAPI.deleteProject(id) : desktopAPI.deleteProject(id),
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
