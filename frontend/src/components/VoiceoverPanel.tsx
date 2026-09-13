import { useEffect, useId, useRef, useState, type RefObject } from 'react';
import { useEditor } from '../store';
import { useRecording } from '../useRecording';
import { clampVoiceoverOffset, clampVoiceoverStart } from '../recording';
import { formatTime } from '../timelineMath';
import type { Voiceover } from '../model';

function NumberSetting({
  label,
  value,
  min,
  max,
  step = 0.05,
  onCommit,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  onCommit: (value: number) => void;
}) {
  const [text, setText] = useState(String(value));
  useEffect(() => setText(String(Number(value.toFixed(3)))), [value]);
  return (
    <label>
      {label}
      <input
        aria-label={label}
        type="number"
        min={min}
        max={max}
        step={step}
        value={text}
        onChange={(event) => setText(event.target.value)}
        onBlur={() => {
          if (text === String(Number(value.toFixed(3)))) return;
          const parsed = Number(text);
          if (text !== '' && Number.isFinite(parsed)) {
            const next = Math.max(min, Math.min(max, parsed));
            setText(String(next));
            if (next !== value) onCommit(next);
          } else setText(String(value));
        }}
        onKeyDown={(event) => {
          if (event.key === 'Enter') event.currentTarget.blur();
        }}
      />
    </label>
  );
}

export function VoiceoverPanel({
  videoRef,
  onSeek,
}: {
  videoRef: RefObject<HTMLVideoElement | null>;
  onSeek: (time: number) => void;
}) {
  const project = useEditor((state) => state.project);
  const recording = useEditor((state) => state.recording);
  const { state, message, start, stop } = useRecording(videoRef);
  const [expanded, setExpanded] = useState(false);
  const toggle = useRef<HTMLButtonElement>(null);
  const close = useRef<HTMLButtonElement>(null);
  const drawerId = useId();
  const closeDrawer = () => {
    setExpanded(false);
    toggle.current?.focus();
  };
  const count = project?.voiceovers.length ?? 0;
  useEffect(() => {
    if (count > 0) setExpanded(true);
  }, [count]);
  if (!project) return null;
  const update = (id: string, change: (clip: Voiceover) => void) =>
    useEditor.getState().edit((draft) => {
      const clip = draft.voiceovers.find((item) => item.id === id);
      if (clip) change(clip);
    });
  return (
    <section
      className={`voiceover-panel ${recording ? 'is-recording' : ''}`}
      aria-label="Voiceover recording"
    >
      <div className="voiceover-bar">
        <button
          className={state === 'recording' ? 'record-button recording' : 'record-button'}
          aria-label={state === 'recording' ? 'Stop recording' : 'Record voiceover'}
          disabled={state === 'permission' || state === 'uploading'}
          onClick={() => {
            if (state === 'recording') stop();
            else void start();
          }}
        >
          <span aria-hidden="true">{state === 'recording' ? '■' : '●'}</span>
          {state === 'recording'
            ? 'Stop recording'
            : state === 'permission'
              ? 'Opening microphone…'
              : state === 'uploading'
                ? 'Saving voiceover…'
                : 'Record voiceover'}
        </button>
        <span className="recording-status" data-testid="recording-status" role="status">
          {state === 'recording'
            ? 'Recording · seeking is locked'
            : message ||
              `${count} voiceover ${count === 1 ? 'clip' : 'clips'} · record from the playhead`}
        </span>
        <button
          ref={toggle}
          className="audio-toggle"
          aria-label="Audio & voiceovers"
          aria-expanded={expanded}
          aria-controls={expanded ? drawerId : undefined}
          onClick={() => {
            if (expanded) closeDrawer();
            else {
              setExpanded(true);
              requestAnimationFrame(() => close.current?.focus());
            }
          }}
        >
          Audio & voiceovers {expanded ? '⌄' : '⌃'}
        </button>
      </div>
      {expanded && (
        <div
          className="audio-drawer"
          id={drawerId}
          role="region"
          aria-label="Audio and voiceover controls"
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.stopPropagation();
              closeDrawer();
            }
          }}
        >
          <div className="audio-drawer-heading">
            <strong>Audio & voiceovers</strong>
            <span>Use headphones while recording.</span>
            <button ref={close} aria-label="Close audio controls" onClick={closeDrawer}>
              ×
            </button>
          </div>
          <fieldset disabled={recording}>
            <div className="audio-settings">
              <NumberSetting
                label="Original audio gain"
                value={project.settings.originalAudioGain}
                min={0}
                max={2}
                onCommit={(gain) =>
                  useEditor.getState().edit((draft) => {
                    draft.settings.originalAudioGain = gain;
                  })
                }
              />
              <label className="check-label">
                <input
                  aria-label="Mute original audio"
                  type="checkbox"
                  checked={project.settings.originalAudioMuted}
                  onChange={(event) =>
                    useEditor.getState().edit((draft) => {
                      draft.settings.originalAudioMuted = event.target.checked;
                    })
                  }
                />
                Mute original audio
              </label>
              <NumberSetting
                label="Voiceover master gain"
                value={project.settings.voiceoverMasterGain}
                min={0}
                max={2}
                onCommit={(gain) =>
                  useEditor.getState().edit((draft) => {
                    draft.settings.voiceoverMasterGain = gain;
                  })
                }
              />
            </div>
            <div className="voiceover-clips">
              {project.voiceovers.length === 0 ? (
                <p>No clips yet. Position the playhead, then record your commentary.</p>
              ) : (
                project.voiceovers.map((clip, index) => (
                  <article
                    className="voiceover-clip"
                    data-testid={`voiceover-${index + 1}`}
                    key={clip.id}
                  >
                    <div className="voiceover-clip-title">
                      <button
                        aria-label={`Play voiceover ${index + 1}`}
                        onClick={() => {
                          onSeek(clip.startSec + clip.timingOffsetMs / 1000);
                          void videoRef.current
                            ?.play()
                            .catch(() =>
                              useEditor.getState().setError('Unable to start voiceover preview.'),
                            );
                        }}
                      >
                        ▶
                      </button>
                      <strong>Voiceover {index + 1}</strong>
                      <span>
                        {formatTime(clip.startSec + clip.timingOffsetMs / 1000)} –{' '}
                        {formatTime(clip.endSec + clip.timingOffsetMs / 1000)}
                      </span>
                      <button
                        aria-label={`Delete voiceover ${index + 1}`}
                        onClick={() =>
                          useEditor.getState().edit((draft) => {
                            draft.voiceovers = draft.voiceovers.filter(
                              (item) => item.id !== clip.id,
                            );
                          })
                        }
                      >
                        Delete
                      </button>
                    </div>
                    <div className="voiceover-clip-controls">
                      <NumberSetting
                        label={`Voiceover ${index + 1} start`}
                        value={clip.startSec}
                        min={Math.max(0, -clip.timingOffsetMs / 1000)}
                        max={
                          project.source.durationSec - clip.durationSec - clip.timingOffsetMs / 1000
                        }
                        step={0.01}
                        onCommit={(value) =>
                          update(clip.id, (item) => {
                            item.startSec = clampVoiceoverStart(
                              value,
                              item.durationSec,
                              item.timingOffsetMs,
                              project.source.durationSec,
                            );
                            item.endSec = item.startSec + item.durationSec;
                          })
                        }
                      />
                      <NumberSetting
                        label={`Voiceover ${index + 1} gain`}
                        value={clip.gain}
                        min={0}
                        max={2}
                        onCommit={(gain) =>
                          update(clip.id, (item) => {
                            item.gain = gain;
                          })
                        }
                      />
                      <NumberSetting
                        label={`Voiceover ${index + 1} timing offset (ms)`}
                        value={clip.timingOffsetMs}
                        min={Math.max(-60000, -clip.startSec * 1000)}
                        max={Math.min(60000, (project.source.durationSec - clip.endSec) * 1000)}
                        step={10}
                        onCommit={(value) =>
                          update(clip.id, (item) => {
                            item.timingOffsetMs = clampVoiceoverOffset(
                              value,
                              item.startSec,
                              item.durationSec,
                              project.source.durationSec,
                            );
                          })
                        }
                      />
                      <label className="check-label">
                        <input
                          aria-label={`Mute voiceover ${index + 1}`}
                          type="checkbox"
                          checked={clip.muted}
                          onChange={(event) =>
                            update(clip.id, (item) => {
                              item.muted = event.target.checked;
                            })
                          }
                        />
                        Mute clip
                      </label>
                    </div>
                  </article>
                ))
              )}
            </div>
            <p className="audio-help">
              Gain 1 = original level. Overlapping clips play together. Timing offset nudges a clip
              without changing the recording. Delete can be undone.
            </p>
          </fieldset>
        </div>
      )}
    </section>
  );
}
