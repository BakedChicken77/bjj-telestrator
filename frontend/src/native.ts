import { Capacitor, registerPlugin, type PluginListenerHandle } from '@capacitor/core';
import { projectSchema, readProject, voiceoverSchema, type Project, type Voiceover } from './model';
import type { ExportJob, ProjectSummary, RuntimeCapabilities } from './api';
import type { Draft } from './project/saveSession';

/** JSON crosses this bridge; video and microphone bytes stay in the iOS sandbox. */
export interface BJJNativePlugin {
  getCapabilities(): Promise<RuntimeCapabilities>;
  recoverProjectCopy(options: { project: Project }): Promise<{ project: unknown }>;
  writeRecoveryDraft(options: { draft: Draft }): Promise<void>;
  getRecoveryDrafts(options: { projectId: string }): Promise<{ drafts: unknown[] }>;
  clearRecoveryDraft(options: {
    projectId: string;
    writerId: string;
    draftId: string;
  }): Promise<void>;
  shareDiagnostics(options: { text: string }): Promise<void>;
  listProjects(): Promise<{ projects: ProjectSummary[] }>;
  getProject(options: { projectId: string }): Promise<{ project: unknown }>;
  importVideo(options: {
    source: 'photos' | 'files';
  }): Promise<{ project?: unknown; cancelled?: boolean }>;
  saveProject(options: {
    project: Project;
    expectedRevision: number;
  }): Promise<{ project: unknown }>;
  deleteProject(options: { projectId: string }): Promise<void>;
  listExports(options: { projectId: string }): Promise<{ jobs: ExportJob[] }>;
  createExport(options: {
    projectId: string;
    expectedRevision: number;
  }): Promise<{ job: ExportJob }>;
  getExport(options: { jobId: string }): Promise<{ job: ExportJob }>;
  cancelExport(options: { jobId: string }): Promise<{ job: ExportJob }>;
  getAssetURL(options: {
    projectId: string;
    kind: 'video' | 'voiceover';
    clipId?: string;
  }): Promise<{ url: string }>;
  shareExport(options: { jobId: string }): Promise<{ completed: boolean }>;
  prepareRecording(options: { projectId: string }): Promise<void>;
  startRecording(options: { startSec: number }): Promise<{ elapsedSec: number }>;
  stopRecording(options: { startSec?: number }): Promise<{ clip?: unknown }>;
  addListener(event: 'appSuspending', callback: () => void): Promise<PluginListenerHandle>;
  addListener(
    event: 'recordingFinished',
    callback: (event: {
      projectId: string;
      clip?: unknown;
      reason: string;
      error?: string;
    }) => void,
  ): Promise<PluginListenerHandle>;
}

export const nativeBridge = registerPlugin<BJJNativePlugin>('BJJNative');
export const isNativeIOS = () => Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios';
const urls = new Map<string, Promise<string>>();

async function nativeAsset(
  projectId: string,
  kind: 'video' | 'voiceover',
  clipId?: string,
): Promise<string> {
  const key = `${projectId}:${kind}:${clipId ?? ''}`;
  let pending = urls.get(key);
  if (!pending) {
    pending = nativeBridge
      .getAssetURL({ projectId, kind, clipId })
      .then(({ url }) => Capacitor.convertFileSrc(url));
    urls.set(key, pending);
    void pending.catch(() => urls.delete(key));
  }
  return pending;
}

export const mediaURL = (projectId: string) =>
  isNativeIOS()
    ? nativeAsset(projectId, 'video')
    : Promise.resolve(`/api/projects/${projectId}/video`);

export const voiceoverURL = (projectId: string, clipId: string) =>
  isNativeIOS()
    ? nativeAsset(projectId, 'voiceover', clipId)
    : Promise.resolve(`/api/projects/${projectId}/voiceovers/${clipId}/audio`);

export const nativeAPI = {
  capabilities: () => nativeBridge.getCapabilities(),
  recoverCopy: async (project: Project) =>
    readProject((await nativeBridge.recoverProjectCopy({ project })).project),
  projects: async () => (await nativeBridge.listProjects()).projects,
  project: async (projectId: string) =>
    readProject((await nativeBridge.getProject({ projectId })).project),
  importVideo: async (source: 'photos' | 'files'): Promise<Project | null> => {
    const result = await nativeBridge.importVideo({ source });
    return result.cancelled ? null : projectSchema.parse(result.project);
  },
  save: async (project: Project) =>
    projectSchema.parse(
      (
        await nativeBridge.saveProject({
          project: projectSchema.parse(project),
          expectedRevision: project.revision,
        })
      ).project,
    ),
  deleteProject: async (projectId: string) => {
    await nativeBridge.deleteProject({ projectId });
    for (const key of urls.keys()) if (key.startsWith(`${projectId}:`)) urls.delete(key);
  },
  exports: async (projectId: string) => (await nativeBridge.listExports({ projectId })).jobs,
  export: async (projectId: string, expectedRevision: number) =>
    (await nativeBridge.createExport({ projectId, expectedRevision })).job,
  exportJob: async (jobId: string) => (await nativeBridge.getExport({ jobId })).job,
  cancelExport: async (jobId: string) => (await nativeBridge.cancelExport({ jobId })).job,
  stopRecording: async (startSec?: number): Promise<Voiceover | null> => {
    const result = await nativeBridge.stopRecording({ startSec });
    return result.clip ? voiceoverSchema.parse(result.clip) : null;
  },
};
