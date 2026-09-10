import { memo, useEffect, useRef, useState } from 'react';
import type { CSSProperties, KeyboardEvent, PointerEvent } from 'react';
import type { Annotation } from '../model';
import { useEditor } from '../store';
import { clamp, formatTime, rulerStep, shiftInterval, trimInterval } from '../timelineMath';
import type { TimeInterval } from '../timelineMath';
import './editor-panels.css';

const LABEL_WIDTH = 132;

interface DragState {
  pointerId: number;
  annotation: Annotation;
  mode: 'move' | 'start' | 'end';
  clientX: number;
  interval: TimeInterval;
}

interface RowProps {
  annotation: Annotation;
  selected: boolean;
  interval: TimeInterval;
  pixelsPerSecond: number;
  trackWidth: number;
  durationSec: number;
  dragging: boolean;
  onSeek: (time: number) => void;
  onStart: (
    event: PointerEvent<HTMLButtonElement>,
    annotation: Annotation,
    mode: DragState['mode'],
  ) => void;
  onMove: (event: PointerEvent<HTMLButtonElement>) => void;
  onEnd: (event: PointerEvent<HTMLButtonElement>) => void;
  onCancel: () => void;
  onKeyboardEdit: (
    event: KeyboardEvent<HTMLButtonElement>,
    annotation: Annotation,
    mode: DragState['mode'],
  ) => void;
}

const titleCase = (text: string): string => text.charAt(0).toUpperCase() + text.slice(1);

// Playback updates only these small controls, not the 100+ annotation rows.
function TimelineClock() {
  const currentTime = useEditor((state) => state.currentTime);
  return (
    <span className="timeline-time" aria-live="off">
      {formatTime(currentTime)}
    </span>
  );
}

function TimelinePlayhead({
  durationSec,
  pixelsPerSecond,
}: {
  durationSec: number;
  pixelsPerSecond: number;
}) {
  const currentTime = useEditor((state) => state.currentTime);
  return (
    <div
      className="timeline-playhead"
      style={{ left: LABEL_WIDTH + clamp(currentTime, 0, durationSec) * pixelsPerSecond }}
    >
      <span />
    </div>
  );
}

function TimeRuler({
  trackWidth,
  pixelsPerSecond,
  durationSec,
  seekStepSec,
  largeSeekStepSec,
  onSeek,
}: {
  trackWidth: number;
  pixelsPerSecond: number;
  durationSec: number;
  seekStepSec: number;
  largeSeekStepSec: number;
  onSeek: (time: number) => void;
}) {
  const currentTime = useEditor((state) => state.currentTime);
  const step = rulerStep(pixelsPerSecond);
  const ticks = Array.from(
    { length: Math.floor(durationSec / step) + 1 },
    (_, index) => index * step,
  );
  const seekAtPointer = (event: PointerEvent<HTMLDivElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    onSeek(clamp((event.clientX - bounds.left) / pixelsPerSecond, 0, durationSec));
  };
  return (
    <div
      className="timeline-ruler"
      style={{ width: trackWidth }}
      role="slider"
      tabIndex={0}
      aria-label="Timeline playhead"
      aria-valuemin={0}
      aria-valuemax={durationSec}
      aria-valuenow={currentTime}
      aria-valuetext={formatTime(currentTime)}
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId);
        seekAtPointer(event);
      }}
      onPointerMove={(event) => {
        if (event.currentTarget.hasPointerCapture(event.pointerId)) seekAtPointer(event);
      }}
      onPointerUp={(event) => {
        if (event.currentTarget.hasPointerCapture(event.pointerId)) {
          seekAtPointer(event);
          event.currentTarget.releasePointerCapture(event.pointerId);
        }
      }}
      onKeyDown={(event) => {
        if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
          event.preventDefault();
          event.stopPropagation();
          const stepSec = event.shiftKey ? largeSeekStepSec : seekStepSec;
          onSeek(
            clamp(currentTime + (event.key === 'ArrowLeft' ? -stepSec : stepSec), 0, durationSec),
          );
        } else if (event.key === 'Home' || event.key === 'End') {
          event.preventDefault();
          event.stopPropagation();
          onSeek(event.key === 'Home' ? 0 : durationSec);
        }
      }}
    >
      {ticks.map((time) => (
        <span className="ruler-tick" style={{ left: time * pixelsPerSecond }} key={time}>
          {formatTime(time).replace(/\.000$/, '')}
        </span>
      ))}
    </div>
  );
}

const AnnotationRow = memo(function AnnotationRow({
  annotation,
  selected,
  interval,
  pixelsPerSecond,
  trackWidth,
  durationSec,
  dragging,
  onSeek,
  onStart,
  onMove,
  onEnd,
  onCancel,
  onKeyboardEdit,
}: RowProps) {
  const select = useEditor((state) => state.select);
  const name =
    annotation.type === 'text' ? annotation.geometry.text || 'Text' : titleCase(annotation.type);
  const intervalLabel = `${formatTime(interval.startSec)} – ${formatTime(interval.endSec)}`;
  const dragEvents = {
    onPointerMove: onMove,
    onPointerUp: onEnd,
    onPointerCancel: onCancel,
  };

  return (
    <div className={`timeline-row${selected ? ' is-selected' : ''}`}>
      <button
        className="timeline-track-label"
        title={name}
        onClick={() => select(annotation.id)}
        aria-pressed={selected}
      >
        <span className="track-color" style={{ background: annotation.strokeColor }} />
        <span>{name}</span>
      </button>
      <div
        className="timeline-track"
        style={{ width: trackWidth }}
        onPointerDown={(event) => {
          if (event.target !== event.currentTarget) return;
          const bounds = event.currentTarget.getBoundingClientRect();
          onSeek(clamp((event.clientX - bounds.left) / pixelsPerSecond, 0, durationSec));
        }}
      >
        <div
          className={`annotation-bar${selected ? ' is-selected' : ''}${dragging ? ' is-dragging' : ''}`}
          style={
            {
              left: interval.startSec * pixelsPerSecond,
              width: Math.max(3, (interval.endSec - interval.startSec) * pixelsPerSecond),
              '--annotation-color': annotation.strokeColor,
            } as CSSProperties
          }
          title={intervalLabel}
        >
          <button
            className="annotation-trim start"
            aria-label={`Trim ${annotation.type} start`}
            onPointerDown={(event) => onStart(event, annotation, 'start')}
            onKeyDown={(event) => onKeyboardEdit(event, annotation, 'start')}
            {...dragEvents}
          />
          <button
            className="annotation-bar-body"
            data-testid={`timeline-annotation-${annotation.id}`}
            aria-label={`${titleCase(annotation.type)} annotation, ${formatTime(interval.startSec)} to ${formatTime(interval.endSec)}`}
            aria-pressed={selected}
            onPointerDown={(event) => onStart(event, annotation, 'move')}
            onClick={() => select(annotation.id)}
            onKeyDown={(event) => onKeyboardEdit(event, annotation, 'move')}
            {...dragEvents}
          >
            <span>{name}</span>
          </button>
          <button
            className="annotation-trim end"
            aria-label={`Trim ${annotation.type} end`}
            onPointerDown={(event) => onStart(event, annotation, 'end')}
            onKeyDown={(event) => onKeyboardEdit(event, annotation, 'end')}
            {...dragEvents}
          />
          {dragging && <output className="timeline-drag-readout">{intervalLabel}</output>}
        </div>
      </div>
    </div>
  );
});

export function Timeline({ onSeek }: { onSeek: (time: number) => void }) {
  const project = useEditor((state) => state.project);
  const selectedId = useEditor((state) => state.selectedId);
  const select = useEditor((state) => state.select);
  const edit = useEditor((state) => state.edit);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [viewportWidth, setViewportWidth] = useState(700);
  const [pixelsPerSecond, setPixelsPerSecond] = useState(32);
  const [drag, setDrag] = useState<DragState | null>(null);
  const dragRef = useRef<DragState | null>(null);
  const durationSec = project?.source.durationSec ?? 0;

  useEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setViewportWidth(entry.contentRect.width);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const width = scrollRef.current?.clientWidth ?? 700;
    if (durationSec > 0)
      setPixelsPerSecond(Math.max(0.01, (width - LABEL_WIDTH - 18) / durationSec));
    if (scrollRef.current) scrollRef.current.scrollLeft = 0;
  }, [project?.projectId, durationSec]);

  useEffect(() => {
    const cancel = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') {
        dragRef.current = null;
        setDrag(null);
      }
    };
    window.addEventListener('keydown', cancel);
    return () => window.removeEventListener('keydown', cancel);
  }, []);

  if (!project) return null;
  const trackWidth = Math.max(viewportWidth - LABEL_WIDTH - 2, durationSec * pixelsPerSecond);
  const annotations = [...project.annotations].sort((a, b) => a.zIndex - b.zIndex);

  const commit = (id: string, interval: TimeInterval) => {
    const previous = project.annotations.find((annotation) => annotation.id === id);
    if (
      !previous ||
      (previous.startSec === interval.startSec && previous.endSec === interval.endSec)
    )
      return;
    edit((draft) => {
      const annotation = draft.annotations.find((item) => item.id === id);
      if (annotation) {
        annotation.startSec = interval.startSec;
        annotation.endSec = interval.endSec;
        annotation.updatedAt = new Date().toISOString();
      }
    });
  };

  const onStart = (
    event: PointerEvent<HTMLButtonElement>,
    annotation: Annotation,
    mode: DragState['mode'],
  ) => {
    if (event.button !== 0 || dragRef.current) return;
    event.preventDefault();
    event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    select(annotation.id);
    const next = {
      pointerId: event.pointerId,
      annotation,
      mode,
      clientX: event.clientX,
      interval: { startSec: annotation.startSec, endSec: annotation.endSec },
    };
    dragRef.current = next;
    setDrag(next);
  };

  const onMove = (event: PointerEvent<HTMLButtonElement>) => {
    const active = dragRef.current;
    if (!active || active.pointerId !== event.pointerId) return;
    const delta = (event.clientX - active.clientX) / pixelsPerSecond;
    const original = active.annotation;
    const interval =
      active.mode === 'move'
        ? shiftInterval(original, delta, durationSec)
        : trimInterval(
            original,
            active.mode,
            (active.mode === 'start' ? original.startSec : original.endSec) + delta,
            durationSec,
          );
    const next = { ...active, interval };
    dragRef.current = next;
    setDrag(next);
  };

  const onEnd = (event: PointerEvent<HTMLButtonElement>) => {
    const active = dragRef.current;
    if (!active || active.pointerId !== event.pointerId) return;
    if (active) commit(active.annotation.id, active.interval);
    dragRef.current = null;
    setDrag(null);
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
  };

  const onKeyboardEdit = (
    event: KeyboardEvent<HTMLButtonElement>,
    annotation: Annotation,
    mode: DragState['mode'],
  ) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    event.stopPropagation();
    const delta =
      (event.key === 'ArrowLeft' ? -1 : 1) *
      (event.shiftKey ? project.settings.largeSeekStepSec : project.settings.seekStepSec);
    commit(
      annotation.id,
      mode === 'move'
        ? shiftInterval(annotation, delta, durationSec)
        : trimInterval(
            annotation,
            mode,
            (mode === 'start' ? annotation.startSec : annotation.endSec) + delta,
            durationSec,
          ),
    );
  };

  return (
    <section className="timeline-panel" aria-label="Annotation timeline">
      <div className="panel-heading timeline-heading">
        <h2>
          Timeline <span className="subtle-count">{annotations.length}</span>
        </h2>
        <div className="timeline-tools">
          <TimelineClock />
          <button
            aria-label="Zoom out timeline"
            onClick={() => setPixelsPerSecond((value) => Math.max(0.01, value / 1.5))}
          >
            −
          </button>
          <button
            aria-label="Zoom in timeline"
            onClick={() => setPixelsPerSecond((value) => Math.min(240, value * 1.5))}
          >
            +
          </button>
          <button
            className="fit-button"
            onClick={() =>
              setPixelsPerSecond(Math.max(0.01, (viewportWidth - LABEL_WIDTH - 18) / durationSec))
            }
          >
            Fit
          </button>
        </div>
      </div>
      <div className="timeline-scroll" ref={scrollRef}>
        <div className="timeline-content" style={{ width: LABEL_WIDTH + trackWidth }}>
          <div className="timeline-ruler-row">
            <div className="timeline-ruler-label">ANNOTATIONS</div>
            <TimeRuler
              trackWidth={trackWidth}
              pixelsPerSecond={pixelsPerSecond}
              durationSec={durationSec}
              seekStepSec={project.settings.seekStepSec}
              largeSeekStepSec={project.settings.largeSeekStepSec}
              onSeek={onSeek}
            />
          </div>
          {annotations.map((annotation) => (
            <AnnotationRow
              key={annotation.id}
              annotation={annotation}
              selected={selectedId === annotation.id}
              interval={drag?.annotation.id === annotation.id ? drag.interval : annotation}
              pixelsPerSecond={pixelsPerSecond}
              trackWidth={trackWidth}
              durationSec={durationSec}
              dragging={drag?.annotation.id === annotation.id}
              onSeek={onSeek}
              onStart={onStart}
              onMove={onMove}
              onEnd={onEnd}
              onCancel={() => {
                dragRef.current = null;
                setDrag(null);
              }}
              onKeyboardEdit={onKeyboardEdit}
            />
          ))}
          {annotations.length === 0 && (
            <div className="timeline-empty">
              Draw on the paused video to add your first annotation.
            </div>
          )}
          <TimelinePlayhead durationSec={durationSec} pixelsPerSecond={pixelsPerSecond} />
        </div>
      </div>
      <div className="timeline-hint">
        Drag a bar to move it · Drag its edges to trim · Select a bar for exact timing
      </div>
    </section>
  );
}

export default Timeline;
