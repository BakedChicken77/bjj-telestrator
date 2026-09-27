import { useState } from 'react';
import type { Annotation } from '../model';
import { annotationBounds, moveAnnotation, resizeAnnotation } from '../canvas';
import { NumberField } from './NumberField';

type Field = [string, string, number, number];
export function GeometryFields({
  annotation,
  width,
  height,
  onUpdate,
}: {
  annotation: Annotation;
  width: number;
  height: number;
  onUpdate: (recipe: (draft: Annotation) => void) => void;
}) {
  const [pointIndex, setPointIndex] = useState(0);
  const bounds = annotationBounds(annotation, width, height);
  const g = annotation.geometry;
  let fields: Field[] = [];
  switch (annotation.type) {
    case 'line':
    case 'arrow':
      fields = [
        ['Start X (%)', 'x1', 0, 1],
        ['Start Y (%)', 'y1', 0, 1],
        ['End X (%)', 'x2', 0, 1],
        ['End Y (%)', 'y2', 0, 1],
      ];
      break;
    case 'rectangle': {
      const g = annotation.geometry;
      fields = [
        ['X (%)', 'x', 0, 1 - g.width],
        ['Y (%)', 'y', 0, 1 - g.height],
        ['Width (%)', 'width', 0.0001, 1 - g.x],
        ['Height (%)', 'height', 0.0001, 1 - g.y],
      ];
      break;
    }
    case 'ellipse': {
      const g = annotation.geometry;
      fields = [
        ['Center X (%)', 'centerX', g.radiusX, 1 - g.radiusX],
        ['Center Y (%)', 'centerY', g.radiusY, 1 - g.radiusY],
        ['Horizontal radius (%)', 'radiusX', 0.0001, Math.min(g.centerX, 1 - g.centerX)],
        ['Vertical radius (%)', 'radiusY', 0.0001, Math.min(g.centerY, 1 - g.centerY)],
      ];
      break;
    }
    case 'text':
      fields = [
        ['X (%)', 'x', 0, 1],
        ['Y (%)', 'y', 0, 1],
      ];
      break;
  }
  const point =
    annotation.type === 'freehand'
      ? annotation.geometry.points[Math.min(pointIndex, annotation.geometry.points.length - 1)]
      : null;
  function replace(next: Annotation) {
    onUpdate((draft) => {
      draft.geometry = next.geometry;
    });
  }
  return (
    <section className="inspector-section" aria-label="Annotation geometry">
      <h3>Position and size</h3>
      <p className="inspector-note">
        Coordinates are percentages of the oriented video picture. Viewing size does not change
        these values.
      </p>
      {fields.map(([label, key, min, max]) => (
        <NumberField
          key={key}
          label={label}
          value={Number((g as Record<string, unknown>)[key]) * 100}
          min={min * 100}
          max={max * 100}
          step={0.1}
          onCommit={(value) =>
            onUpdate((draft) => {
              draft.geometry = { ...draft.geometry, [key]: value / 100 };
            })
          }
        />
      ))}
      {annotation.type === 'freehand' && point && (
        <>
          <NumberField
            label="Freehand point number"
            value={Math.min(pointIndex + 1, annotation.geometry.points.length)}
            min={1}
            max={annotation.geometry.points.length}
            step={1}
            onCommit={(value) => setPointIndex(Math.round(value) - 1)}
          />
          {(['x', 'y'] as const).map((axis) => (
            <NumberField
              key={axis}
              label={`Point ${axis.toUpperCase()} (%)`}
              value={point[axis] * 100}
              min={0}
              max={100}
              step={0.1}
              onCommit={(value) =>
                onUpdate((draft) => {
                  if (draft.type === 'freehand')
                    draft.geometry.points[Math.min(pointIndex, draft.geometry.points.length - 1)]![
                      axis
                    ] = value / 100;
                })
              }
            />
          ))}
          <button
            disabled={annotation.geometry.points.length >= 4000}
            onClick={() =>
              onUpdate((draft) => {
                if (draft.type !== 'freehand') return;
                const index = Math.min(pointIndex, draft.geometry.points.length - 1);
                const a = draft.geometry.points[index]!,
                  b = draft.geometry.points[index + 1] ?? a;
                draft.geometry.points.splice(index + 1, 0, {
                  x: (a.x + b.x) / 2,
                  y: (a.y + b.y) / 2,
                });
              })
            }
          >
            Insert point after selection
          </button>
          <button
            disabled={annotation.geometry.points.length <= 2}
            onClick={() =>
              onUpdate((draft) => {
                if (draft.type === 'freehand')
                  draft.geometry.points.splice(
                    Math.min(pointIndex, draft.geometry.points.length - 1),
                    1,
                  );
              })
            }
          >
            Remove selected point
          </button>
          <NumberField
            label="Path width (%)"
            value={bounds.width * 100}
            min={0.1}
            max={(1 - bounds.x) * 100}
            step={0.1}
            onCommit={(value) =>
              replace(
                resizeAnnotation(
                  annotation,
                  3,
                  { x: bounds.x + value / 100, y: bounds.y + bounds.height },
                  width,
                  height,
                ),
              )
            }
          />
          <NumberField
            label="Path height (%)"
            value={bounds.height * 100}
            min={0.1}
            max={(1 - bounds.y) * 100}
            step={0.1}
            onCommit={(value) =>
              replace(
                resizeAnnotation(
                  annotation,
                  3,
                  { x: bounds.x + bounds.width, y: bounds.y + value / 100 },
                  width,
                  height,
                ),
              )
            }
          />
        </>
      )}
      <div className="geometry-nudges">
        {(
          [
            ['left', -0.01, 0],
            ['right', 0.01, 0],
            ['up', 0, -0.01],
            ['down', 0, 0.01],
          ] as const
        ).map(([name, dx, dy]) => (
          <button
            key={name}
            onClick={() => replace(moveAnnotation(annotation, dx, dy, width, height))}
          >
            Move {name} 1%
          </button>
        ))}
      </div>
    </section>
  );
}
