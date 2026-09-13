import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fixture } from './testFixtures';

const harness = vi.hoisted(() => ({
  native: false,
  plugin: {
    listProjects: vi.fn(),
    getProject: vi.fn(),
    importVideo: vi.fn(),
    saveProject: vi.fn(),
    deleteProject: vi.fn(),
    duplicateProject: vi.fn(),
    listCheckpoints: vi.fn(),
    createCheckpoint: vi.fn(),
    restoreCheckpoint: vi.fn(),
    listDeletedProjects: vi.fn(),
    restoreDeletedProject: vi.fn(),
    permanentlyDeleteProject: vi.fn(),
    getAssetURL: vi.fn(),
    listExports: vi.fn(),
    createExport: vi.fn(),
    getExport: vi.fn(),
    cancelExport: vi.fn(),
    retryExport: vi.fn(),
    removeExportFile: vi.fn(),
    getProjectStorage: vi.fn(),
    stopRecording: vi.fn(),
  },
}));
vi.mock('@capacitor/core', () => ({
  Capacitor: {
    isNativePlatform: () => harness.native,
    getPlatform: () => (harness.native ? 'ios' : 'web'),
    convertFileSrc: (url: string) => url,
  },
  registerPlugin: () => harness.plugin,
}));
import { api } from './api';
import { mediaURL, nativeAPI, voiceoverURL } from './native';

beforeEach(() => {
  harness.native = false;
  vi.clearAllMocks();
  vi.unstubAllGlobals();
});

describe('desktop / standalone iPhone API routing', () => {
  it('retries native snapshots and removes only completed outputs without posting project JSON', async () => {
    harness.native = true;
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    const job = {
      jobId: 'attempt',
      projectId: 'project',
      projectRevision: 2,
      retryAvailable: true,
    };
    harness.plugin.retryExport.mockResolvedValue({ job });
    harness.plugin.removeExportFile.mockResolvedValue({ job: { ...job, outputAvailable: false } });
    harness.plugin.getProjectStorage.mockResolvedValue({
      sourceBytes: 123,
      recordingsRetained: true,
    });
    expect(await api.retryExport('old-attempt')).toEqual(job);
    expect(harness.plugin.retryExport).toHaveBeenCalledWith({ jobId: 'old-attempt' });
    expect((await api.removeExportFile('attempt')).outputAvailable).toBe(false);
    expect(harness.plugin.removeExportFile).toHaveBeenCalledWith({ jobId: 'attempt' });
    expect((await api.storage('project')).recordingsRetained).toBe(true);
    expect(fetch).not.toHaveBeenCalled();
  });

  it('routes recovery controls to scoped native storage with confirmed revisions', async () => {
    harness.native = true;
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    const project = fixture();
    const checkpoint = {
      checkpointId: 'checkpoint',
      projectId: project.projectId,
      revision: 7,
      label: 'Before',
      createdAt: project.createdAt,
    };
    harness.plugin.duplicateProject.mockResolvedValue({ project });
    harness.plugin.createCheckpoint.mockResolvedValue({ checkpoint });
    harness.plugin.listCheckpoints.mockResolvedValue({ checkpoints: [checkpoint] });
    harness.plugin.restoreCheckpoint.mockResolvedValue({ project });
    harness.plugin.listDeletedProjects.mockResolvedValue({ projects: [] });
    harness.plugin.restoreDeletedProject.mockResolvedValue({ project, copied: true });
    expect(await api.createCheckpoint(project.projectId, 7, 'Before')).toEqual(checkpoint);
    expect(harness.plugin.createCheckpoint).toHaveBeenCalledWith({
      projectId: project.projectId,
      expectedRevision: 7,
      label: 'Before',
    });
    expect(await api.checkpoints(project.projectId)).toEqual([checkpoint]);
    expect(await api.restoreCheckpoint(project.projectId, 'checkpoint', 8)).toEqual(project);
    expect(harness.plugin.restoreCheckpoint).toHaveBeenCalledWith({
      projectId: project.projectId,
      expectedRevision: 8,
      checkpointId: 'checkpoint',
    });
    expect(await api.duplicateProject(project.projectId, 8)).toEqual(project);
    expect(harness.plugin.duplicateProject).toHaveBeenCalledWith({
      projectId: project.projectId,
      expectedRevision: 8,
    });
    await api.deleteProject(project.projectId, 8);
    expect(harness.plugin.deleteProject).toHaveBeenCalledWith({
      projectId: project.projectId,
      expectedRevision: 8,
    });
    expect(await api.deletedProjects()).toEqual([]);
    expect((await api.restoreDeletedProject('trash')).copied).toBe(true);
    await api.permanentlyDeleteProject('trash');
    expect(harness.plugin.permanentlyDeleteProject).toHaveBeenCalledWith({ trashId: 'trash' });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('keeps browser media on the desktop HTTP routes', async () => {
    expect(await mediaURL('example')).toBe('/api/projects/example/video');
    expect(await voiceoverURL('example', 'clip')).toBe(
      '/api/projects/example/voiceovers/clip/audio',
    );
    expect(harness.plugin.getAssetURL).not.toHaveBeenCalled();
  });
  it('loads and validates a native project without an HTTP server', async () => {
    harness.native = true;
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    harness.plugin.getProject.mockResolvedValue({ project: fixture() });
    expect((await api.project(fixture().projectId)).projectId).toBe(fixture().projectId);
    expect(harness.plugin.getProject).toHaveBeenCalledWith({ projectId: fixture().projectId });
    expect(fetch).not.toHaveBeenCalled();
  });
  it('rejects invalid native data before it enters the editor', async () => {
    harness.native = true;
    harness.plugin.getProject.mockResolvedValue({ project: { ...fixture(), schemaVersion: 9 } });
    await expect(api.project(fixture().projectId)).rejects.toThrow();
  });
  it('validates edits before calling native storage', async () => {
    harness.native = true;
    await expect(api.save({ ...fixture(), projectName: '' })).rejects.toThrow();
    expect(harness.plugin.saveProject).not.toHaveBeenCalled();
  });
  it('treats cancelled Photos selection as a normal cancellation', async () => {
    harness.plugin.importVideo.mockResolvedValue({ cancelled: true });
    expect(await nativeAPI.importVideo('photos')).toBeNull();
    expect(harness.plugin.importVideo).toHaveBeenCalledWith({ source: 'photos' });
  });
  it('retrieves media URLs through UUID references and caches duplicate requests', async () => {
    harness.native = true;
    const id = '11111111-1111-4111-8111-123456789abc';
    harness.plugin.getAssetURL.mockResolvedValue({
      url: `capacitor://localhost/bjj-media/${id}/video.mp4`,
    });
    const [first, second] = await Promise.all([mediaURL(id), mediaURL(id)]);
    expect(first).toBe(second);
    expect(harness.plugin.getAssetURL).toHaveBeenCalledTimes(1);
    expect(harness.plugin.getAssetURL).toHaveBeenCalledWith({
      projectId: id,
      kind: 'video',
      clipId: undefined,
    });
  });
  it('retries an asset lookup after a transient native error', async () => {
    harness.native = true;
    harness.plugin.getAssetURL
      .mockRejectedValueOnce(new Error('locked'))
      .mockResolvedValueOnce({ url: 'capacitor://localhost/bjj-media/retry/video.mp4' });
    await expect(mediaURL('retry')).rejects.toThrow('locked');
    await expect(mediaURL('retry')).resolves.toContain('retry/video.mp4');
  });
  it('returns native export progress and cancellation without HTTP calls', async () => {
    harness.native = true;
    const job = { jobId: 'job', status: 'queued' };
    harness.plugin.createExport.mockResolvedValue({ job });
    expect(await api.export('project', 1)).toEqual(job);
    harness.plugin.cancelExport.mockResolvedValue({ job: { ...job, status: 'cancelled' } });
    expect((await api.cancelExport('job')).status).toBe('cancelled');
  });
});
