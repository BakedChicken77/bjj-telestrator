import { describe, expect, it, vi } from 'vitest';
import { annotationSchema } from './model';
import {
  annotationBounds,
  annotationInterval,
  containedRect,
  createAnnotation,
  moveAnnotation,
  normalizedPoint,
  resizeAnnotation,
  samplePoint,
  visibleAt,
} from './canvas';

describe('video coordinate mapping', () => {
  it('excludes horizontal letterboxing', () => {
    const picture = containedRect(1000, 1000, 1920, 1080);
    expect(picture).toEqual({ x: 0, y: 218.75, width: 1000, height: 562.5 });
    expect(normalizedPoint(500, 500, picture)).toEqual({ x: 0.5, y: 0.5 });
    expect(normalizedPoint(500, 218.75, picture)).toEqual({ x: 0.5, y: 0 });
    expect(normalizedPoint(1200, 100, picture)).toEqual({ x: 1, y: 0 });
  });

  it('excludes pillarboxing for portrait footage and remains size independent', () => {
    const picture = containedRect(1000, 600, 1080, 1920);
    expect(picture).toEqual({ x: 331.25, y: 0, width: 337.5, height: 600 });
    expect(normalizedPoint(500, 300, picture)).toEqual({ x: 0.5, y: 0.5 });
    expect(containedRect(500, 300, 1080, 1920)).toEqual({
      x: 165.625,
      y: 0,
      width: 168.75,
      height: 300,
    });
  });
});

describe('temporal creation and visibility', () => {
  it('creates valid unique annotation IDs when a WebView omits randomUUID', () => {
    const getRandomValues = crypto.getRandomValues.bind(crypto);
    vi.stubGlobal('crypto', { getRandomValues });
    try {
      const annotations = Array.from({ length: 20 }, () =>
        createAnnotation('arrow', { x: 0.1, y: 0.2 }, { x: 0.5, y: 0.7 }, 1, 20, 5, 1),
      );
      expect(annotations.every((a) => annotationSchema.safeParse(a).success)).toBe(true);
      expect(new Set(annotations.map((a) => a.id)).size).toBe(20);
      expect(annotations.every((a) => a.id[14] === '4')).toBe(true);
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it('uses a half-open media-time interval including exact boundaries', () => {
    const interval = annotationInterval(84, 120, 5);
    expect(interval).toEqual({ startSec: 84, endSec: 89 });
    expect([83.999, 84, 88.999, 89].map((time) => visibleAt(interval, time))).toEqual([
      false,
      true,
      true,
      false,
    ]);
  });

  it('clamps end and provides a valid interval when drawing at video end', () => {
    expect(annotationInterval(18, 20, 5)).toEqual({ startSec: 18, endSec: 20 });
    const interval = annotationInterval(20, 20, 5);
    expect(interval.startSec).toBeLessThan(interval.endSec);
    expect(interval.endSec).toBe(20);
  });
});

describe('annotation geometry editing', () => {
  it.each(['line', 'arrow', 'rectangle', 'ellipse', 'freehand', 'text'] as const)(
    'creates a valid %s with normalized geometry',
    (type) => {
      const annotation = createAnnotation(
        type,
        { x: 0.2, y: 0.3 },
        { x: 0.7, y: 0.8 },
        5,
        20,
        5,
        0,
      );
      expect(annotationSchema.safeParse(annotation).success).toBe(true);
      expect(annotation.startSec).toBe(5);
      expect(annotation.endSec).toBe(10);
    },
  );

  it('keeps zero-width shapes valid when a drag follows the picture edge', () => {
    for (const type of ['rectangle', 'ellipse'] as const) {
      const annotation = createAnnotation(type, { x: 1, y: 1 }, { x: 1, y: 0.5 }, 1, 20, 5, 0);
      expect(annotationSchema.safeParse(annotation).success).toBe(true);
    }
  });

  it('moves a complete arrow as one geometry and clamps at picture boundaries', () => {
    const arrow = createAnnotation('arrow', { x: 0.2, y: 0.2 }, { x: 0.7, y: 0.6 }, 5, 20, 5, 0);
    const moved = moveAnnotation(arrow, 0.5, -0.5);
    if (moved.type !== 'arrow') throw new Error('Unexpected annotation type');
    expect(moved.geometry.x1).toBeCloseTo(0.5);
    expect(moved.geometry.x2).toBeCloseTo(1);
    expect(moved.geometry.y1).toBeCloseTo(0);
    expect(moved.geometry.y2).toBeCloseTo(0.4);
    expect(arrow.geometry.x1).toBe(0.2);
    expect(annotationSchema.safeParse(moved).success).toBe(true);
  });

  it('resizes an ellipse from a corner around its opposite corner', () => {
    const ellipse = createAnnotation(
      'ellipse',
      { x: 0.2, y: 0.2 },
      { x: 0.6, y: 0.6 },
      5,
      20,
      5,
      0,
    );
    const resized = resizeAnnotation(ellipse, 0, { x: 0.1, y: 0.1 });
    const bounds = annotationBounds(resized);
    expect(bounds.x).toBeCloseTo(0.1);
    expect(bounds.y).toBeCloseTo(0.1);
    expect(bounds.width).toBeCloseTo(0.5);
    expect(bounds.height).toBeCloseTo(0.5);
    expect(annotationSchema.safeParse(resized).success).toBe(true);
  });

  it('samples freehand by visible distance and keeps long gestures bounded', () => {
    const points = [{ x: 0.1, y: 0.1 }];
    expect(samplePoint(points, { x: 0.101, y: 0.1 }, 1000, 1000)).toBe(points);
    expect(samplePoint(points, { x: 0.11, y: 0.1 }, 1000, 1000)).toHaveLength(2);
    const long = Array.from({ length: 4000 }, (_, index) => ({ x: index / 5000, y: 0.5 }));
    expect(samplePoint(long, { x: 1, y: 0.5 }, 1000, 1000)).toHaveLength(2001);
  });
});
