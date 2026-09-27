import { describe, expect, it } from 'vitest';
import { arrow, fixture } from './testFixtures';
import { annotationInterval, isVisible, projectSchema, type Annotation } from './model';

describe('media-time semantics', () => {
  it('uses a half-open interval at exact and adjacent times', () => {
    const item = arrow();
    expect([4.999, 5, 9.999, 10].map((time) => isVisible(item, time))).toEqual([
      false,
      true,
      true,
      false,
    ]);
  });
  it('creates five-second intervals and clamps near the end', () => {
    expect(annotationInterval(84, 120)).toEqual({ startSec: 84, endSec: 89 });
    expect(annotationInterval(18, 20)).toEqual({ startSec: 18, endSec: 20 });
    expect(annotationInterval(7, 20, 2)).toEqual({ startSec: 7, endSec: 9 });
    expect(annotationInterval(20, 20).startSec).toBeLessThan(20);
  });
});

describe('versioned project validation', () => {
  it('round-trips unknown fields at project, annotation, geometry and settings levels', () => {
    const project = fixture();
    project.annotations = [arrow()];
    project.futureFeature = { enabled: true };
    project.settings.futureSetting = 7;
    project.annotations[0].futureAnnotation = 'kept';
    project.annotations[0].geometry.futureGeometry = 0.25;
    expect(projectSchema.parse(project)).toEqual(project);
  });
  it('rejects duplicate identifiers and intervals outside the video', () => {
    const project = fixture();
    project.annotations = [arrow(), arrow()];
    expect(projectSchema.safeParse(project).success).toBe(false);
    project.annotations = [{ ...arrow(), endSec: 21 }];
    expect(projectSchema.safeParse(project).success).toBe(false);
    project.annotations = [{ ...arrow(), startSec: 10 }];
    expect(projectSchema.safeParse(project).success).toBe(false);
  });
  it('rejects unsafe media references, invalid colors, nonfinite geometry and future versions', () => {
    for (const unsafe of [
      '/etc/passwd',
      '../original.mp4',
      'proxy//file.mp4',
      'C:/file.mp4',
      'proxy/file\0.mp4',
      'proxy\\file.mp4',
    ]) {
      const project = fixture();
      project.source.asset = unsafe;
      expect(projectSchema.safeParse(project).success, unsafe).toBe(false);
    }
    const project = fixture();
    project.annotations = [{ ...arrow(), strokeColor: 'red' }];
    expect(projectSchema.safeParse(project).success).toBe(false);
    project.annotations = [arrow()];
    project.annotations[0].geometry.x1 = Number.NaN;
    expect(projectSchema.safeParse(project).success).toBe(false);
    expect(projectSchema.safeParse({ ...fixture(), schemaVersion: 99 }).success).toBe(false);
  });
  it('enforces backend domains for names, text, gains, freehand smoothing and z ordering', () => {
    expect(projectSchema.safeParse({ ...fixture(), projectName: 'x'.repeat(161) }).success).toBe(
      false,
    );
    const project = fixture();
    project.annotations = [{ ...arrow(), zIndex: -1 }];
    expect(projectSchema.safeParse(project).success).toBe(false);
    project.annotations = [];
    project.settings.voiceoverMasterGain = 2.1;
    expect(projectSchema.safeParse(project).success).toBe(false);
    project.settings.voiceoverMasterGain = 1;
    project.annotations = [
      {
        ...arrow(),
        type: 'freehand',
        geometry: {
          points: [
            { x: 0, y: 0 },
            { x: 1, y: 1 },
          ],
          smoothing: 0.5,
        },
      } as unknown as Annotation,
    ];
    expect(projectSchema.safeParse(project).success).toBe(false);
  });
});
