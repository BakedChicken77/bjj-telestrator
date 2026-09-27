import type { Annotation, Project } from './model';

export function fixture(): Project {
  const media = {
    asset: 'source/11111111-1111-4111-8111-111111111111.mp4',
    originalFilename: 'rolling.mp4',
    durationSec: 20,
    codec: 'h264',
    audioCodec: 'aac',
    hasAudio: true,
    codedWidth: 1920,
    codedHeight: 1080,
    displayWidth: 1920,
    displayHeight: 1080,
    sampleAspectRatio: '1:1',
    displayAspectRatio: '16:9',
    rotation: 0,
    avgFrameRate: 30,
  };
  return {
    schemaVersion: 2,
    revision: 1,
    requiredCapabilities: ['project.revisions.v1'],
    projectId: '11111111-1111-4111-8111-111111111111',
    projectName: 'Round one',
    createdAt: '2026-09-05T12:00:00Z',
    updatedAt: '2026-09-05T12:00:00Z',
    source: media,
    proxy: { ...media, asset: 'proxy/22222222-2222-4222-8222-222222222222.mp4' },
    settings: {
      defaultAnnotationDuration: 5,
      seekStepSec: 0.1,
      largeSeekStepSec: 1,
      originalAudioGain: 1,
      originalAudioMuted: false,
      voiceoverMasterGain: 1,
    },
    exportSettings: { fps: 30, crf: 18, preset: 'medium' },
    annotations: [],
    voiceovers: [],
  };
}

export function arrow(): Annotation {
  return {
    id: '33333333-3333-4333-8333-333333333333',
    type: 'arrow',
    startSec: 5,
    endSec: 10,
    zIndex: 0,
    strokeColor: '#ff3333',
    strokeWidth: 0.006,
    strokeOpacity: 1,
    fillColor: '#ff3333',
    fillOpacity: 0,
    geometry: { x1: 0.2, y1: 0.3, x2: 0.6, y2: 0.8, arrowheadSize: 0.025 },
    createdAt: '2026-09-05T12:00:00Z',
    updatedAt: '2026-09-05T12:00:00Z',
  };
}
