import type { Annotation, Tool } from './model';
import { annotationInterval } from './model';
import { newUUID } from './uuid';
export { annotationInterval, isVisible as visibleAt } from './model';

export type Point = { x: number; y: number };
export interface Bounds {
  x: number;
  y: number;
  width: number;
  height: number;
}
export const clamp = (value: number, low = 0, high = 1): number =>
  Math.min(high, Math.max(low, value));

/** Only this rectangle is video; letterbox bars never enter stored geometry. */
export function containedRect(
  width: number,
  height: number,
  videoWidth: number,
  videoHeight: number,
): Bounds {
  if (width <= 0 || height <= 0 || videoWidth <= 0 || videoHeight <= 0)
    return { x: 0, y: 0, width: 0, height: 0 };
  const scale = Math.min(width / videoWidth, height / videoHeight);
  const pictureWidth = Math.min(width, videoWidth * scale);
  const pictureHeight = Math.min(height, videoHeight * scale);
  return {
    x: (width - pictureWidth) / 2,
    y: (height - pictureHeight) / 2,
    width: pictureWidth,
    height: pictureHeight,
  };
}

export function normalizedPoint(x: number, y: number, rectangle: Bounds): Point {
  return {
    x: clamp((x - rectangle.x) / (rectangle.width || 1)),
    y: clamp((y - rectangle.y) / (rectangle.height || 1)),
  };
}

export function createAnnotation(
  tool: Exclude<Tool, 'select'>,
  start: Point,
  end: Point,
  time: number,
  duration: number,
  defaultDuration: number,
  zIndex: number,
  points: Point[] = [],
): Annotation {
  const timestamp = new Date().toISOString();
  const base = {
    id: newUUID(),
    ...annotationInterval(time, duration, defaultDuration),
    zIndex,
    strokeColor: '#ef4444',
    strokeWidth: 0.006,
    strokeOpacity: 1,
    fillColor: '#ef4444',
    fillOpacity: 0,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
  const box = {
    x: Math.min(0.9999, start.x, end.x),
    y: Math.min(0.9999, start.y, end.y),
    width: Math.max(0.0001, Math.abs(end.x - start.x)),
    height: Math.max(0.0001, Math.abs(end.y - start.y)),
  };
  switch (tool) {
    case 'line':
      return { ...base, type: tool, geometry: { x1: start.x, y1: start.y, x2: end.x, y2: end.y } };
    case 'arrow':
      return {
        ...base,
        type: tool,
        geometry: { x1: start.x, y1: start.y, x2: end.x, y2: end.y, arrowheadSize: 0.025 },
      };
    case 'rectangle':
      return { ...base, type: tool, geometry: box };
    case 'ellipse':
      return {
        ...base,
        type: tool,
        geometry: {
          centerX: box.x + box.width / 2,
          centerY: box.y + box.height / 2,
          radiusX: box.width / 2,
          radiusY: box.height / 2,
        },
      };
    case 'freehand':
      return {
        ...base,
        type: tool,
        geometry: { points: points.length > 1 ? points : [start, end], smoothing: 0 },
      };
    case 'text':
      return {
        ...base,
        type: tool,
        geometry: {
          x: start.x,
          y: start.y,
          text: 'Label',
          fontSize: 0.04,
          alignment: 'left',
          backgroundColor: '#000000',
          backgroundOpacity: 0,
        },
      };
  }
}

export function textDimensions(
  annotation: Extract<Annotation, { type: 'text' }>,
  width: number,
  height: number,
): { width: number; height: number } {
  const fontSize = annotation.geometry.fontSize * Math.min(width, height);
  const lines = annotation.geometry.text.split('\n');
  let measure = (line: string): number => line.length * fontSize * 0.6;
  if (typeof document !== 'undefined') {
    const context = document.createElement('canvas').getContext('2d');
    if (context) {
      context.font = `${fontSize}px "DejaVu Sans"`;
      measure = (line) => context.measureText(line).width;
    }
  }
  return {
    width: Math.max(fontSize / 2, ...lines.map(measure)),
    height: fontSize * lines.length * 1.2,
  };
}

export function annotationBounds(annotation: Annotation, width = 1, height = 1): Bounds {
  switch (annotation.type) {
    case 'line':
    case 'arrow': {
      const g = annotation.geometry;
      return {
        x: Math.min(g.x1, g.x2),
        y: Math.min(g.y1, g.y2),
        width: Math.abs(g.x2 - g.x1),
        height: Math.abs(g.y2 - g.y1),
      };
    }
    case 'rectangle':
      return annotation.geometry;
    case 'ellipse': {
      const g = annotation.geometry;
      return {
        x: g.centerX - g.radiusX,
        y: g.centerY - g.radiusY,
        width: g.radiusX * 2,
        height: g.radiusY * 2,
      };
    }
    case 'freehand': {
      const x = annotation.geometry.points.map((p) => p.x);
      const y = annotation.geometry.points.map((p) => p.y);
      return {
        x: Math.min(...x),
        y: Math.min(...y),
        width: Math.max(...x) - Math.min(...x),
        height: Math.max(...y) - Math.min(...y),
      };
    }
    case 'text': {
      const measured = textDimensions(annotation, width, height);
      const w = measured.width / width;
      const factor =
        annotation.geometry.alignment === 'left'
          ? 0
          : annotation.geometry.alignment === 'center'
            ? 0.5
            : 1;
      return {
        x: annotation.geometry.x - w * factor,
        y: annotation.geometry.y,
        width: w,
        height: measured.height / height,
      };
    }
  }
}

/** Transform a complete shape, preserving normalized geometry and point order. */
export function transformAnnotation(
  annotation: Annotation,
  map: (point: Point) => Point,
): Annotation {
  switch (annotation.type) {
    case 'line':
    case 'arrow': {
      const a = map({ x: annotation.geometry.x1, y: annotation.geometry.y1 });
      const b = map({ x: annotation.geometry.x2, y: annotation.geometry.y2 });
      // The existing discriminant and arrowhead field are preserved by the spread.
      return {
        ...annotation,
        geometry: { ...annotation.geometry, x1: a.x, y1: a.y, x2: b.x, y2: b.y },
      } as Annotation;
    }
    case 'rectangle': {
      const g = annotation.geometry;
      const a = map(g);
      const b = map({ x: g.x + g.width, y: g.y + g.height });
      return {
        ...annotation,
        geometry: {
          ...g,
          x: Math.min(a.x, b.x),
          y: Math.min(a.y, b.y),
          width: Math.abs(b.x - a.x),
          height: Math.abs(b.y - a.y),
        },
      };
    }
    case 'ellipse': {
      const g = annotation.geometry;
      const a = map({ x: g.centerX - g.radiusX, y: g.centerY - g.radiusY });
      const b = map({ x: g.centerX + g.radiusX, y: g.centerY + g.radiusY });
      return {
        ...annotation,
        geometry: {
          ...g,
          centerX: (a.x + b.x) / 2,
          centerY: (a.y + b.y) / 2,
          radiusX: Math.abs(b.x - a.x) / 2,
          radiusY: Math.abs(b.y - a.y) / 2,
        },
      };
    }
    case 'freehand':
      return {
        ...annotation,
        geometry: {
          ...annotation.geometry,
          points: annotation.geometry.points.map((point) => ({ ...point, ...map(point) })),
        },
      };
    case 'text':
      return { ...annotation, geometry: { ...annotation.geometry, ...map(annotation.geometry) } };
  }
}

export function moveAnnotation(
  annotation: Annotation,
  dx: number,
  dy: number,
  width = 1,
  height = 1,
): Annotation {
  const bounds = annotationBounds(annotation, width, height);
  const constrainedX = clamp(dx, -bounds.x, Math.max(-bounds.x, 1 - bounds.x - bounds.width));
  const constrainedY = clamp(dy, -bounds.y, Math.max(-bounds.y, 1 - bounds.y - bounds.height));
  return transformAnnotation(annotation, (p) => ({
    x: clamp(p.x + constrainedX),
    y: clamp(p.y + constrainedY),
  }));
}

export function resizeAnnotation(
  annotation: Annotation,
  corner: number,
  point: Point,
  width = 1,
  height = 1,
): Annotation {
  const bounds = annotationBounds(annotation, width, height);
  const opposite = {
    x: bounds.x + (corner % 2 === 0 ? bounds.width : 0),
    y: bounds.y + (corner < 2 ? bounds.height : 0),
  };
  const minimum = 0.001;
  const nx =
    corner % 2 === 0
      ? Math.min(point.x, opposite.x - minimum)
      : Math.max(point.x, opposite.x + minimum);
  const ny =
    corner < 2 ? Math.min(point.y, opposite.y - minimum) : Math.max(point.y, opposite.y + minimum);
  const next = {
    x: clamp(Math.min(nx, opposite.x)),
    y: clamp(Math.min(ny, opposite.y)),
    width: Math.abs(nx - opposite.x),
    height: Math.abs(ny - opposite.y),
  };
  const scaleX = next.width / Math.max(bounds.width, minimum);
  const scaleY = next.height / Math.max(bounds.height, minimum);
  const changed = transformAnnotation(annotation, (p) => ({
    x: clamp(next.x + (p.x - bounds.x) * scaleX),
    y: clamp(next.y + (p.y - bounds.y) * scaleY),
  }));
  if (changed.type === 'text' && annotation.type === 'text')
    changed.geometry.fontSize = clamp(
      annotation.geometry.fontSize * Math.min(scaleX, scaleY),
      0.005,
      0.5,
    );
  return changed;
}

/** Samples at two display pixels; the explicit last point preserves the endpoint. */
export function samplePoint(points: Point[], point: Point, width: number, height: number): Point[] {
  const last = points[points.length - 1];
  if (!last || Math.hypot((point.x - last.x) * width, (point.y - last.y) * height) >= 2) {
    // Retain practical detail while bounding project size during long gestures.
    const retained = points.length >= 4000 ? points.filter((_, index) => index % 2 === 0) : points;
    return [...retained, point];
  }
  return points;
}
