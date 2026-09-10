import { projectSchema, voiceoverSchema, type Project } from './model';
import { isNativeIOS, nativeAPI } from './native';

export interface ProjectSummary {
  projectId: string;
  projectName: string;
  updatedAt: string;
  durationSec: number;
  annotationCount: number;
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
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, init);
  } catch {
    throw new Error(
      'Cannot connect to BJJ Telestrator. Check that the local backend is running, then retry.',
    );
  }
  if (!response.ok) {
    let message = `Request failed (${response.status}).`;
    try {
      const error: { detail?: unknown } = await response.json();
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
    throw new Error(message);
  }
  return response.status === 204 ? (undefined as T) : (response.json() as Promise<T>);
}

const desktopAPI = {
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
  project: async (id: string) => projectSchema.parse(await request<unknown>(`/api/projects/${id}`)),
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
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(projectSchema.parse(project)),
      }),
    ),
  deleteProject: (id: string) => request<void>(`/api/projects/${id}`, { method: 'DELETE' }),
  exports: (id: string) => request<ExportJob[]>(`/api/projects/${id}/exports`),
  export: (id: string) => request<ExportJob>(`/api/projects/${id}/exports`, { method: 'POST' }),
  exportJob: (id: string) => request<ExportJob>(`/api/exports/${id}`),
  cancelExport: (id: string) => request<ExportJob>(`/api/exports/${id}/cancel`, { method: 'POST' }),
};

/** Keep the verified desktop HTTP path; iOS uses an entirely local native service. */
export const api = {
  ...desktopAPI,
  projects: () => (isNativeIOS() ? nativeAPI.projects() : desktopAPI.projects()),
  project: (id: string) => (isNativeIOS() ? nativeAPI.project(id) : desktopAPI.project(id)),
  save: (project: Project) => (isNativeIOS() ? nativeAPI.save(project) : desktopAPI.save(project)),
  deleteProject: (id: string) =>
    isNativeIOS() ? nativeAPI.deleteProject(id) : desktopAPI.deleteProject(id),
  exports: (id: string) => (isNativeIOS() ? nativeAPI.exports(id) : desktopAPI.exports(id)),
  export: (id: string) => (isNativeIOS() ? nativeAPI.export(id) : desktopAPI.export(id)),
  exportJob: (id: string) => (isNativeIOS() ? nativeAPI.exportJob(id) : desktopAPI.exportJob(id)),
  cancelExport: (id: string) =>
    isNativeIOS() ? nativeAPI.cancelExport(id) : desktopAPI.cancelExport(id),
};
