import { useEffect, useId, useState } from 'react';
import type { Annotation } from '../model';
import { useEditor } from '../store';
import { clamp, formatTime, parseTime, trimInterval } from '../timelineMath';
import './editor-panels.css';

interface NumberFieldProps {
  label: string;
  value: number;
  onCommit: (value: number) => void;
  min: number;
  max: number;
  step?: number;
  help?: string;
}

function NumberField({ label, value, onCommit, min, max, step = 0.1, help }: NumberFieldProps) {
  const [input, setInput] = useState(String(Number(value.toFixed(4))));
  const [error, setError] = useState('');
  const id = useId();
  useEffect(() => {
    setInput(String(Number(value.toFixed(4))));
    setError('');
  }, [value]);
  const commit = () => {
    if (input === String(Number(value.toFixed(4)))) {
      setError('');
      return;
    }
    const parsed = Number(input);
    if (!input.trim() || !Number.isFinite(parsed) || parsed < min || parsed > max) {
      setError(`Enter a value from ${Number(min.toFixed(3))} to ${Number(max.toFixed(3))}.`);
      return;
    }
    setError('');
    if (parsed !== value) onCommit(parsed);
  };
  return (
    <label className="inspector-field" htmlFor={id}>
      <span>{label}</span>
      <input
        id={id}
        aria-label={label}
        type="number"
        inputMode="decimal"
        min={min}
        max={max}
        step={step}
        value={input}
        aria-invalid={!!error}
        onChange={(event) => setInput(event.target.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            event.currentTarget.blur();
          }
          if (event.key === 'Escape') {
            setInput(String(value));
            setError('');
            event.stopPropagation();
          }
        }}
      />
      {error ? (
        <span role="alert" className="field-error">
          {error}
        </span>
      ) : (
        help && <small>{help}</small>
      )}
    </label>
  );
}

function TimeField({
  label,
  value,
  onCommit,
  max,
}: {
  label: string;
  value: number;
  max: number;
  onCommit: (value: number) => number;
}) {
  const [input, setInput] = useState(formatTime(value));
  const [error, setError] = useState('');
  const id = useId();
  useEffect(() => {
    setInput(formatTime(value));
    setError('');
  }, [value]);
  const commit = () => {
    if (input === formatTime(value)) {
      setError('');
      return;
    }
    const parsed = parseTime(input);
    if (parsed === null || parsed > max) {
      setError(`Use seconds or MM:SS.mmm, up to ${formatTime(max)}.`);
      return;
    }
    setError('');
    setInput(formatTime(onCommit(parsed)));
  };
  return (
    <label className="inspector-field" htmlFor={id}>
      <span>{label}</span>
      <input
        id={id}
        aria-label={label}
        inputMode="decimal"
        value={input}
        aria-invalid={!!error}
        onChange={(event) => setInput(event.target.value)}
        onBlur={commit}
        onKeyDown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            event.currentTarget.blur();
          }
          if (event.key === 'Escape') {
            setInput(formatTime(value));
            setError('');
            event.stopPropagation();
          }
        }}
      />
      {error && (
        <span role="alert" className="field-error">
          {error}
        </span>
      )}
    </label>
  );
}

function ColorField({
  label,
  value,
  onCommit,
}: {
  label: string;
  value: string;
  onCommit: (value: string) => void;
}) {
  const [input, setInput] = useState(value);
  const id = useId();
  useEffect(() => {
    setInput(value);
  }, [value]);
  return (
    <label className="inspector-field color-field" htmlFor={id}>
      <span>{label}</span>
      <div className="color-control">
        <input
          id={id}
          aria-label={label}
          type="color"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          onBlur={() => {
            if (input !== value) onCommit(input);
          }}
        />
        <span>{input.toUpperCase()}</span>
        <button
          className="apply-color"
          type="button"
          disabled={input === value}
          aria-label={`Apply ${label.toLowerCase()}`}
          onClick={() => onCommit(input)}
        >
          Apply
        </button>
      </div>
    </label>
  );
}

function TextField({ value, onCommit }: { value: string; onCommit: (text: string) => void }) {
  const [input, setInput] = useState(value);
  useEffect(() => {
    setInput(value);
  }, [value]);
  return (
    <label className="inspector-field">
      <span>Text content</span>
      <textarea
        aria-label="Text content"
        value={input}
        rows={3}
        maxLength={2000}
        onChange={(event) => setInput(event.target.value)}
        onBlur={() => {
          if (input.trim() && input !== value) onCommit(input);
          else if (!input.trim()) setInput(value);
        }}
      />
    </label>
  );
}

export function Inspector() {
  const project = useEditor((state) => state.project);
  const selectedId = useEditor((state) => state.selectedId);
  const edit = useEditor((state) => state.edit);
  const select = useEditor((state) => state.select);
  if (!project) return null;
  const annotation = project.annotations.find((item) => item.id === selectedId);
  const durationSec = project.source.durationSec;
  const minimumSize = Math.min(project.source.displayWidth, project.source.displayHeight);
  const update = (recipe: (draft: Annotation) => void) => {
    if (!annotation) return;
    edit((draft) => {
      const target = draft.annotations.find((item) => item.id === annotation.id);
      if (target) {
        const previous = JSON.stringify(target);
        recipe(target);
        if (JSON.stringify(target) !== previous) target.updatedAt = new Date().toISOString();
      }
    });
  };
  const changeTime = (edge: 'start' | 'end', time: number) => {
    if (!annotation) return time;
    const next = trimInterval(annotation, edge, time, durationSec);
    if (next.startSec !== annotation.startSec || next.endSec !== annotation.endSec) {
      update((draft) => {
        draft.startSec = next.startSec;
        draft.endSec = next.endSec;
      });
    }
    return edge === 'start' ? next.startSec : next.endSec;
  };
  const ordered = [...project.annotations].sort((a, b) => a.zIndex - b.zIndex);
  const layerIndex = ordered.findIndex((item) => item.id === selectedId);
  const reorder = (direction: -1 | 1) => {
    const nextIndex = layerIndex + direction;
    if (layerIndex < 0 || nextIndex < 0 || nextIndex >= ordered.length) return;
    const ids = ordered.map((item) => item.id);
    [ids[layerIndex], ids[nextIndex]] = [ids[nextIndex]!, ids[layerIndex]!];
    edit((draft) => {
      for (const item of draft.annotations) {
        const nextZ = ids.indexOf(item.id);
        if (item.zIndex !== nextZ) {
          item.zIndex = nextZ;
          item.updatedAt = new Date().toISOString();
        }
      }
    });
  };

  return (
    <aside className="inspector-panel" aria-label="Properties inspector">
      <div className="panel-heading">
        <h2>Properties</h2>
        <span className="panel-eyebrow">{annotation ? 'SELECTION' : 'PROJECT'}</span>
      </div>
      <div className="inspector-scroll">
        {annotation ? (
          <div key={annotation.id}>
            <section className="inspector-section">
              <div className="selected-object-heading">
                <span className="selection-color" style={{ background: annotation.strokeColor }} />
                <h3>
                  {annotation.type === 'ellipse'
                    ? 'Ellipse / circle'
                    : annotation.type.charAt(0).toUpperCase() + annotation.type.slice(1)}
                </h3>
              </div>
              <p className="inspector-note">Visible from its start time, until its end time.</p>
              <TimeField
                label="Start time"
                value={annotation.startSec}
                max={durationSec}
                onCommit={(time) => changeTime('start', time)}
              />
              <TimeField
                label="End time"
                value={annotation.endSec}
                max={durationSec}
                onCommit={(time) => changeTime('end', time)}
              />
              <NumberField
                label="Duration (seconds)"
                value={annotation.endSec - annotation.startSec}
                min={Math.min(0.001, durationSec)}
                max={durationSec - annotation.startSec}
                step={0.001}
                onCommit={(value) => changeTime('end', annotation.startSec + value)}
              />
            </section>
            <section className="inspector-section">
              <h3>Appearance</h3>
              <ColorField
                label="Stroke color"
                value={annotation.strokeColor}
                onCommit={(value) =>
                  update((draft) => {
                    draft.strokeColor = value;
                  })
                }
              />
              {annotation.type !== 'text' && (
                <NumberField
                  label="Stroke width (px)"
                  value={annotation.strokeWidth * minimumSize}
                  min={0.001 * minimumSize}
                  max={0.1 * minimumSize}
                  step={0.5}
                  onCommit={(value) =>
                    update((draft) => {
                      draft.strokeWidth = value / minimumSize;
                    })
                  }
                />
              )}
              <NumberField
                label="Opacity (%)"
                value={annotation.strokeOpacity * 100}
                min={0}
                max={100}
                step={1}
                onCommit={(value) =>
                  update((draft) => {
                    draft.strokeOpacity = value / 100;
                  })
                }
              />
              {(annotation.type === 'rectangle' || annotation.type === 'ellipse') && (
                <>
                  <ColorField
                    label="Fill color"
                    value={annotation.fillColor}
                    onCommit={(value) =>
                      update((draft) => {
                        draft.fillColor = value;
                      })
                    }
                  />
                  <NumberField
                    label="Fill opacity (%)"
                    value={annotation.fillOpacity * 100}
                    min={0}
                    max={100}
                    step={1}
                    onCommit={(value) =>
                      update((draft) => {
                        draft.fillOpacity = value / 100;
                      })
                    }
                  />
                </>
              )}
              {annotation.type === 'arrow' && (
                <NumberField
                  label="Arrowhead size (px)"
                  value={annotation.geometry.arrowheadSize * minimumSize}
                  min={0.005 * minimumSize}
                  max={0.2 * minimumSize}
                  step={0.5}
                  onCommit={(value) =>
                    update((draft) => {
                      if (draft.type === 'arrow')
                        draft.geometry.arrowheadSize = value / minimumSize;
                    })
                  }
                />
              )}
              {annotation.type === 'text' && (
                <>
                  <TextField
                    value={annotation.geometry.text}
                    onCommit={(value) =>
                      update((draft) => {
                        if (draft.type === 'text') draft.geometry.text = value;
                      })
                    }
                  />
                  <NumberField
                    label="Text size (px)"
                    value={annotation.geometry.fontSize * minimumSize}
                    min={0.005 * minimumSize}
                    max={0.5 * minimumSize}
                    step={1}
                    onCommit={(value) =>
                      update((draft) => {
                        if (draft.type === 'text') draft.geometry.fontSize = value / minimumSize;
                      })
                    }
                  />
                  <label className="inspector-field">
                    <span>Text alignment</span>
                    <select
                      aria-label="Text alignment"
                      value={annotation.geometry.alignment}
                      onChange={(event) => {
                        const value = event.target.value;
                        if (value === 'left' || value === 'center' || value === 'right')
                          update((draft) => {
                            if (draft.type === 'text') draft.geometry.alignment = value;
                          });
                      }}
                    >
                      <option value="left">Left</option>
                      <option value="center">Center</option>
                      <option value="right">Right</option>
                    </select>
                  </label>
                  <ColorField
                    label="Text background color"
                    value={annotation.geometry.backgroundColor}
                    onCommit={(value) =>
                      update((draft) => {
                        if (draft.type === 'text') draft.geometry.backgroundColor = value;
                      })
                    }
                  />
                  <NumberField
                    label="Text background opacity (%)"
                    value={annotation.geometry.backgroundOpacity * 100}
                    min={0}
                    max={100}
                    step={1}
                    onCommit={(value) =>
                      update((draft) => {
                        if (draft.type === 'text') draft.geometry.backgroundOpacity = value / 100;
                      })
                    }
                  />
                </>
              )}
              <p className="inspector-note">Pixel sizes refer to the original video resolution.</p>
            </section>
            <section className="inspector-section">
              <h3>Layer order</h3>
              <div className="inspector-button-pair">
                <button onClick={() => reorder(-1)} disabled={layerIndex <= 0}>
                  Send backward
                </button>
                <button onClick={() => reorder(1)} disabled={layerIndex >= ordered.length - 1}>
                  Bring forward
                </button>
              </div>
              <button
                className="delete-annotation"
                onClick={() => {
                  edit((draft) => {
                    draft.annotations = draft.annotations.filter(
                      (item) => item.id !== annotation.id,
                    );
                  });
                  select(null);
                }}
              >
                Delete annotation
              </button>
            </section>
          </div>
        ) : (
          <div className="inspector-empty">
            <div className="inspector-empty-symbol">↖</div>
            <h3>Select an annotation</h3>
            <p>
              Click a shape on the video or a bar in the timeline to edit its timing and appearance.
            </p>
          </div>
        )}
        <section className="inspector-section project-settings">
          <h3>Project settings</h3>
          <NumberField
            label="Default annotation duration"
            value={project.settings.defaultAnnotationDuration}
            min={0.01}
            max={3600}
            step={0.5}
            help="Seconds for each new annotation."
            onCommit={(value) =>
              edit((draft) => {
                draft.settings.defaultAnnotationDuration = value;
              })
            }
          />
          <div className="inspector-two-columns">
            <NumberField
              label="Small seek (s)"
              value={project.settings.seekStepSec}
              min={0.001}
              max={60}
              step={0.1}
              onCommit={(value) =>
                edit((draft) => {
                  draft.settings.seekStepSec = value;
                })
              }
            />
            <NumberField
              label="Large seek (s)"
              value={project.settings.largeSeekStepSec}
              min={0.001}
              max={600}
              step={1}
              onCommit={(value) =>
                edit((draft) => {
                  draft.settings.largeSeekStepSec = value;
                })
              }
            />
          </div>
          <p className="inspector-note">
            ← / → seek · Shift seeks farther
            <br />
            Space plays or pauses · Esc clears selection
          </p>
        </section>
        <section className="inspector-section media-summary">
          <h3>Source video</h3>
          <dl>
            <div>
              <dt>Picture</dt>
              <dd>
                {project.source.displayWidth} × {project.source.displayHeight}
              </dd>
            </div>
            <div>
              <dt>Duration</dt>
              <dd>{formatTime(durationSec)}</dd>
            </div>
            <div>
              <dt>Frame rate</dt>
              <dd>{Number(clamp(project.source.avgFrameRate, 0, 1000).toFixed(3))} fps</dd>
            </div>
            <div>
              <dt>Audio</dt>
              <dd>
                {project.source.hasAudio
                  ? (project.source.audioCodec?.toUpperCase() ?? 'Present')
                  : 'No audio'}
              </dd>
            </div>
          </dl>
        </section>
      </div>
    </aside>
  );
}

export default Inspector;
