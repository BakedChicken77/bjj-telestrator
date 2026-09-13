import { useState } from 'react';
import { createAnnotation } from '../canvas';
import type { Tool } from '../model';
import { useEditor } from '../store';
import { formatTime } from '../timelineMath';

/** Semantic entry points use the same objects, validation and undo as the canvas. */
export function AnnotationAccess({ onSeek }: { onSeek: (time: number) => void }) {
  const project = useEditor((state) => state.project);
  const selected = useEditor((state) => state.selectedId);
  const playing = useEditor((state) => state.playing);
  const [kind, setKind] = useState<Exclude<Tool, 'select'>>('arrow');
  if (!project) return null;
  const annotations = [...project.annotations].sort(
    (a, b) => a.zIndex - b.zIndex || a.id.localeCompare(b.id),
  );
  const active = project.annotations.find((item) => item.id === selected);
  function add() {
    const state = useEditor.getState();
    if (!state.project || state.recording || state.playing) return;
    if (state.currentTime >= state.project.source.durationSec) {
      state.setError('Seek before the end of the video to create an annotation.');
      return;
    }
    const item = createAnnotation(
      kind,
      { x: 0.3, y: 0.3 },
      { x: 0.6, y: 0.6 },
      state.currentTime,
      state.project.source.durationSec,
      state.project.settings.defaultAnnotationDuration,
      Math.max(-1, ...state.project.annotations.map((item) => item.zIndex)) + 1,
    );
    state.edit((draft) => {
      draft.annotations.push(item);
    });
    state.select(item.id);
    state.setTool('select');
  }
  return (
    <section
      className="inspector-section annotation-access"
      aria-label="Annotation list and creation"
    >
      <h3>Annotations without dragging</h3>
      <label>
        Annotation selection
        <select
          aria-label="Annotation selection"
          value={selected ?? ''}
          onChange={(event) => useEditor.getState().select(event.target.value || null)}
        >
          <option value="">Project settings</option>
          {annotations.map((item, index) => (
            <option key={item.id} value={item.id}>
              Layer {index + 1}: {item.type}
              {item.type === 'text' ? ` “${item.geometry.text.slice(0, 35)}”` : ''} ·{' '}
              {formatTime(item.startSec)}–{formatTime(item.endSec)}
            </option>
          ))}
        </select>
      </label>
      <button
        disabled={!active}
        onClick={() => {
          if (active) onSeek(active.startSec);
        }}
      >
        Go to annotation start
      </button>
      <label>
        New annotation type
        <select
          aria-label="New annotation type"
          value={kind}
          onChange={(event) => setKind(event.target.value as Exclude<Tool, 'select'>)}
        >
          {(['line', 'arrow', 'ellipse', 'rectangle', 'freehand', 'text'] as const).map((value) => (
            <option key={value} value={value}>
              {value[0].toUpperCase() + value.slice(1)}
            </option>
          ))}
        </select>
      </label>
      <button disabled={playing} onClick={add}>
        Add annotation at playhead
      </button>
      <p className="inspector-note">
        Pause to add a centered cue, then edit its coordinates, timing and style below. Freehand
        points can also be edited individually.
      </p>
    </section>
  );
}
