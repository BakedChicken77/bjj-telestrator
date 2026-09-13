import { memo, useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import { Arrow, Circle, Ellipse, Group, Layer, Line, Rect, Stage, Text } from 'react-konva';
import type { KonvaEventObject } from 'konva/lib/Node';
import type { Annotation } from '../model';
import { useEditor } from '../store';
import { useAudioPreview } from '../useAudioPreview';
import { mediaURL } from '../native';
import {
  annotationBounds,
  clamp,
  containedRect,
  createAnnotation,
  moveAnnotation,
  normalizedPoint,
  resizeAnnotation,
  samplePoint,
  textDimensions,
  visibleAt,
  type Bounds,
  type Point,
} from '../canvas';

type PointerEvent = KonvaEventObject<globalThis.PointerEvent>;
interface Props {
  videoRef: RefObject<HTMLVideoElement | null>;
  onSeek: (time: number) => void;
}
interface Drawing {
  kind: 'draw';
  original: Annotation;
  start: Point;
  points: Point[];
  moved: boolean;
}
interface Moving {
  kind: 'move';
  original: Annotation;
  start: Point;
  moved: boolean;
}
interface Resizing {
  kind: 'resize';
  original: Annotation;
  corner: number;
  moved: boolean;
}
interface Endpoint {
  kind: 'endpoint';
  original: Annotation;
  endpoint: number;
  moved: boolean;
}
type Interaction = Drawing | Moving | Resizing | Endpoint;

export function formatMediaTime(value: number): string {
  const milliseconds = Math.round(Math.max(0, value) * 1000);
  const minutes = Math.floor(milliseconds / 60000);
  const seconds = Math.floor(milliseconds / 1000) % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}.${String(milliseconds % 1000).padStart(3, '0')}`;
}

const AnnotationShape = memo(function AnnotationShape({
  annotation,
  width,
  height,
  selectable,
  onDown,
}: {
  annotation: Annotation;
  width: number;
  height: number;
  selectable: boolean;
  onDown: (annotation: Annotation, event: PointerEvent) => void;
}) {
  const smaller = Math.min(width, height);
  const stroke = {
    stroke: annotation.strokeColor,
    strokeWidth: annotation.strokeWidth * smaller,
    opacity: annotation.strokeOpacity,
    lineCap: 'round' as const,
    lineJoin: 'round' as const,
    hitStrokeWidth: Math.max(12, annotation.strokeWidth * smaller),
  };
  const filled = { fill: annotation.fillColor, opacity: annotation.fillOpacity, listening: false };
  let shape;
  switch (annotation.type) {
    case 'line': {
      const p = annotation.geometry;
      shape = (
        <Line points={[p.x1 * width, p.y1 * height, p.x2 * width, p.y2 * height]} {...stroke} />
      );
      break;
    }
    case 'arrow': {
      const p = annotation.geometry;
      shape = (
        <Arrow
          points={[p.x1 * width, p.y1 * height, p.x2 * width, p.y2 * height]}
          {...stroke}
          fill={annotation.strokeColor}
          pointerLength={p.arrowheadSize * smaller}
          pointerWidth={p.arrowheadSize * smaller}
        />
      );
      break;
    }
    case 'rectangle': {
      const p = annotation.geometry;
      const geometry = {
        x: p.x * width,
        y: p.y * height,
        width: p.width * width,
        height: p.height * height,
      };
      shape = (
        <>
          <Rect {...geometry} {...filled} />
          <Rect {...geometry} {...stroke} />
        </>
      );
      break;
    }
    case 'ellipse': {
      const p = annotation.geometry;
      const geometry = {
        x: p.centerX * width,
        y: p.centerY * height,
        radiusX: p.radiusX * width,
        radiusY: p.radiusY * height,
      };
      shape = (
        <>
          <Ellipse {...geometry} {...filled} />
          <Ellipse {...geometry} {...stroke} />
        </>
      );
      break;
    }
    case 'freehand':
      shape = (
        <Line
          points={annotation.geometry.points.flatMap((p) => [p.x * width, p.y * height])}
          {...stroke}
        />
      );
      break;
    case 'text': {
      const p = annotation.geometry;
      const measured = textDimensions(annotation, width, height);
      const alignmentFactor = p.alignment === 'left' ? 0 : p.alignment === 'center' ? 0.5 : 1;
      const x = p.x * width - measured.width * alignmentFactor;
      shape = (
        <>
          <Rect
            x={x}
            y={p.y * height}
            width={measured.width}
            height={measured.height}
            fill={p.backgroundColor}
            opacity={p.backgroundOpacity}
            listening={false}
          />
          <Text
            x={x}
            y={p.y * height}
            width={measured.width + 1}
            text={p.text}
            fontFamily="DejaVu Sans"
            fontSize={p.fontSize * smaller}
            lineHeight={1.2}
            fill={annotation.strokeColor}
            opacity={annotation.strokeOpacity}
            align={p.alignment}
          />
        </>
      );
      break;
    }
  }
  return (
    <Group listening={selectable} onPointerDown={(event) => onDown(annotation, event)}>
      {shape}
    </Group>
  );
});

function SelectionHandles({
  annotation,
  width,
  height,
  onDown,
}: {
  annotation: Annotation;
  width: number;
  height: number;
  onDown: (kind: 'resize' | 'endpoint', index: number, event: PointerEvent) => void;
}) {
  const handle = {
    radius: 5,
    fill: '#ffffff',
    stroke: '#60a5fa',
    strokeWidth: 2,
    hitStrokeWidth: 28,
  };
  if (annotation.type === 'line' || annotation.type === 'arrow') {
    const p = annotation.geometry;
    return (
      <Group>
        <Circle
          x={p.x1 * width}
          y={p.y1 * height}
          {...handle}
          onPointerDown={(event) => onDown('endpoint', 0, event)}
        />
        <Circle
          x={p.x2 * width}
          y={p.y2 * height}
          {...handle}
          onPointerDown={(event) => onDown('endpoint', 1, event)}
        />
      </Group>
    );
  }
  const bounds = annotationBounds(annotation, width, height);
  const corners = [
    { x: bounds.x, y: bounds.y },
    { x: bounds.x + bounds.width, y: bounds.y },
    { x: bounds.x, y: bounds.y + bounds.height },
    { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
  ];
  return (
    <Group>
      <Rect
        x={bounds.x * width}
        y={bounds.y * height}
        width={bounds.width * width}
        height={bounds.height * height}
        stroke="#60a5fa"
        strokeWidth={1}
        dash={[4, 4]}
        listening={false}
      />
      {corners.map((point, index) => (
        <Circle
          key={index}
          x={point.x * width}
          y={point.y * height}
          {...handle}
          onPointerDown={(event) => onDown('resize', index, event)}
        />
      ))}
    </Group>
  );
}

export function VideoStage({ videoRef, onSeek }: Props) {
  const project = useEditor((state) => state.project);
  const tool = useEditor((state) => state.tool);
  const selectedId = useEditor((state) => state.selectedId);
  const currentTime = useEditor((state) => state.currentTime);
  const playing = useEditor((state) => state.playing);
  const recording = useEditor((state) => state.recording);
  const viewportRef = useRef<HTMLDivElement>(null);
  const pictureRef = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState({ width: 960, height: 540 });
  const [preview, setPreview] = useState<Annotation | null>(null);
  const previewRef = useRef<Annotation | null>(null);
  const interaction = useRef<Interaction | null>(null);
  const [playbackError, setPlaybackError] = useState('');
  const [videoURL, setVideoURL] = useState<string>();
  const [browserVolume, setBrowserVolume] = useState(1);
  const audioPreview = useAudioPreview(videoRef, project, browserVolume, recording);
  const videoWidth = project?.source.displayWidth ?? 16;
  const videoHeight = project?.source.displayHeight ?? 9;
  const picture = containedRect(viewport.width, viewport.height, videoWidth, videoHeight);
  const pictureSize = useRef<Bounds>(picture);
  pictureSize.current = picture;
  const duration = project?.source.durationSec ?? 0;
  const projectId = project?.projectId;
  const proxyReference = project?.proxy.asset;
  const activePointer = useRef<number | null>(null);

  useEffect(() => {
    let disposed = false;
    setVideoURL(undefined);
    setPlaybackError('');
    if (projectId)
      void mediaURL(projectId, proxyReference)
        .then((url) => {
          if (!disposed) setVideoURL(url);
        })
        .catch((cause: unknown) => {
          if (!disposed)
            setPlaybackError(
              cause instanceof Error ? cause.message : 'The local video is unavailable.',
            );
        });
    return () => {
      disposed = true;
    };
  }, [projectId, proxyReference]);

  useEffect(() => {
    const element = viewportRef.current;
    if (!element) return;
    const observer = new ResizeObserver((entries) => {
      const rect = entries[0].contentRect;
      setViewport({ width: rect.width, height: rect.height });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !projectId) return;
    let frameId = 0;
    let animationId = 0;
    let disposed = false;
    const updateTime = (time = video.currentTime) =>
      useEditor.getState().setTime(clamp(time, 0, duration));
    const stopClock = () => {
      if (frameId && 'cancelVideoFrameCallback' in video) video.cancelVideoFrameCallback(frameId);
      cancelAnimationFrame(animationId);
      frameId = 0;
      animationId = 0;
    };
    const tickFrame: VideoFrameRequestCallback = (_now, metadata) => {
      if (disposed || video.paused || video.ended) return;
      updateTime(metadata.mediaTime);
      frameId = video.requestVideoFrameCallback(tickFrame);
    };
    const tickFallback = () => {
      if (disposed || video.paused || video.ended) return;
      updateTime();
      animationId = requestAnimationFrame(tickFallback);
    };
    const play = () => {
      stopClock();
      useEditor.getState().setPlaying(true);
      if ('requestVideoFrameCallback' in video)
        frameId = video.requestVideoFrameCallback(tickFrame);
      else animationId = requestAnimationFrame(tickFallback);
    };
    const pause = () => {
      stopClock();
      updateTime();
      useEditor.getState().setPlaying(false);
    };
    const seek = () => updateTime();
    const loaded = () => {
      setPlaybackError('');
      updateTime();
    };
    const error = () =>
      setPlaybackError(
        'Video playback failed. Reload the project, or reimport the source to rebuild its editing proxy.',
      );
    video.addEventListener('play', play);
    video.addEventListener('pause', pause);
    video.addEventListener('ended', pause);
    video.addEventListener('seeking', seek);
    video.addEventListener('seeked', seek);
    video.addEventListener('loadedmetadata', loaded);
    video.addEventListener('error', error);
    return () => {
      disposed = true;
      stopClock();
      video.removeEventListener('play', play);
      video.removeEventListener('pause', pause);
      video.removeEventListener('ended', pause);
      video.removeEventListener('seeking', seek);
      video.removeEventListener('seeked', seek);
      video.removeEventListener('loadedmetadata', loaded);
      video.removeEventListener('error', error);
    };
  }, [projectId, duration, videoRef]);

  const setLive = useCallback((annotation: Annotation | null) => {
    previewRef.current = annotation;
    setPreview(annotation);
  }, []);

  const finishInteraction = useCallback(() => {
    const gesture = interaction.current;
    const result = previewRef.current;
    interaction.current = null;
    activePointer.current = null;
    setLive(null);
    if (!gesture || !result || (!gesture.moved && gesture.kind !== 'draw')) return;
    if (gesture.kind === 'draw' && !gesture.moved && result.type !== 'text') return;
    const editor = useEditor.getState();
    editor.edit((draft) => {
      if (gesture.kind === 'draw') draft.annotations.push(result);
      else {
        const index = draft.annotations.findIndex((annotation) => annotation.id === result.id);
        if (index >= 0)
          draft.annotations[index] = { ...result, updatedAt: new Date().toISOString() };
      }
    });
    editor.select(result.id);
    editor.setTool('select');
  }, [setLive]);

  useEffect(() => {
    const move = (event: globalThis.PointerEvent) => {
      const gesture = interaction.current;
      const rectangle = pictureRef.current?.getBoundingClientRect();
      if (!gesture || !rectangle || event.pointerId !== activePointer.current) return;
      event.preventDefault();
      const point = normalizedPoint(event.clientX, event.clientY, {
        x: rectangle.left,
        y: rectangle.top,
        width: rectangle.width,
        height: rectangle.height,
      });
      const size = pictureSize.current;
      gesture.moved = true;
      if (gesture.kind === 'draw') {
        const original = gesture.original;
        gesture.points = samplePoint(gesture.points, point, size.width, size.height);
        const editor = useEditor.getState();
        if (!editor.project) return;
        const next = createAnnotation(
          original.type,
          gesture.start,
          point,
          original.startSec,
          editor.project.source.durationSec,
          original.endSec - original.startSec,
          original.zIndex,
          gesture.points,
        );
        setLive({
          ...next,
          id: original.id,
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
        });
      } else if (gesture.kind === 'move') {
        setLive(
          moveAnnotation(
            gesture.original,
            point.x - gesture.start.x,
            point.y - gesture.start.y,
            size.width,
            size.height,
          ),
        );
      } else if (gesture.kind === 'resize') {
        setLive(resizeAnnotation(gesture.original, gesture.corner, point, size.width, size.height));
      } else if (gesture.original.type === 'line' || gesture.original.type === 'arrow') {
        const original = gesture.original;
        const geometry =
          gesture.endpoint === 0
            ? { ...original.geometry, x1: point.x, y1: point.y }
            : { ...original.geometry, x2: point.x, y2: point.y };
        setLive({ ...original, geometry } as Annotation);
      }
    };
    const cancel = () => {
      interaction.current = null;
      activePointer.current = null;
      setLive(null);
    };
    const pointerUp = (event: globalThis.PointerEvent) => {
      if (event.pointerId === activePointer.current) finishInteraction();
    };
    const pointerCancel = (event: globalThis.PointerEvent) => {
      if (event.pointerId === activePointer.current) cancel();
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') cancel();
    };
    window.addEventListener('pointermove', move, { passive: false });
    window.addEventListener('pointerup', pointerUp);
    window.addEventListener('pointercancel', pointerCancel);
    window.addEventListener('keydown', escape);
    return () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', pointerUp);
      window.removeEventListener('pointercancel', pointerCancel);
      window.removeEventListener('keydown', escape);
    };
  }, [finishInteraction, setLive]);

  useEffect(() => {
    interaction.current = null;
    activePointer.current = null;
    setLive(null);
  }, [project?.projectId, setLive]);

  const eventPoint = (event: PointerEvent): Point => {
    const position = event.target.getStage()?.getPointerPosition() ?? { x: 0, y: 0 };
    return normalizedPoint(position.x, position.y, {
      x: 0,
      y: 0,
      width: picture.width,
      height: picture.height,
    });
  };

  const beginMove = useCallback(
    (annotation: Annotation, event: PointerEvent) => {
      if (useEditor.getState().recording || activePointer.current !== null) return;
      event.cancelBubble = true;
      event.evt.preventDefault();
      videoRef.current?.pause();
      useEditor.getState().select(annotation.id);
      const rectangle = pictureRef.current?.getBoundingClientRect();
      if (!rectangle) return;
      activePointer.current = event.evt.pointerId;
      const start = normalizedPoint(event.evt.clientX, event.evt.clientY, {
        x: rectangle.left,
        y: rectangle.top,
        width: rectangle.width,
        height: rectangle.height,
      });
      interaction.current = { kind: 'move', original: annotation, start, moved: false };
      setLive(annotation);
    },
    [setLive, videoRef],
  );

  const beginDraw = (event: PointerEvent) => {
    if (
      !project ||
      event.evt.button !== 0 ||
      useEditor.getState().recording ||
      activePointer.current !== null
    )
      return;
    event.evt.preventDefault();
    const editor = useEditor.getState();
    if (tool === 'select') {
      editor.select(null);
      return;
    }
    videoRef.current?.pause();
    activePointer.current = event.evt.pointerId;
    const start = eventPoint(event);
    const annotation = createAnnotation(
      tool,
      start,
      start,
      editor.currentTime,
      duration,
      project.settings.defaultAnnotationDuration,
      Math.max(0, ...project.annotations.map((a) => a.zIndex)) + 1,
    );
    if (annotation.startSec !== editor.currentTime) onSeek(annotation.startSec);
    interaction.current = {
      kind: 'draw',
      original: annotation,
      start,
      points: [start],
      moved: false,
    };
    setLive(annotation);
  };

  const beginHandle = (kind: 'resize' | 'endpoint', index: number, event: PointerEvent) => {
    if (useEditor.getState().recording || activePointer.current !== null) return;
    event.cancelBubble = true;
    event.evt.preventDefault();
    const selected = project?.annotations.find((annotation) => annotation.id === selectedId);
    if (!selected) return;
    activePointer.current = event.evt.pointerId;
    videoRef.current?.pause();
    interaction.current =
      kind === 'resize'
        ? { kind, original: selected, corner: index, moved: false }
        : { kind, original: selected, endpoint: index, moved: false };
    setLive(selected);
  };

  const active = (project?.annotations ?? [])
    .filter((annotation) => visibleAt(annotation, currentTime))
    .sort((a, b) => a.zIndex - b.zIndex);
  const selected =
    preview?.id === selectedId
      ? preview
      : active.find((annotation) => annotation.id === selectedId);
  const drawn =
    preview && !active.some((annotation) => annotation.id === preview.id)
      ? [...active, preview]
      : active;
  const togglePlayback = async () => {
    if (useEditor.getState().recording) return;
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) {
      try {
        await video.play();
        setPlaybackError('');
      } catch {
        setPlaybackError(
          'Playback could not start. Check that the backend is running and reload the project.',
        );
      }
    } else video.pause();
  };

  return (
    <section className="video-stage" aria-label="Video editor">
      <div className="video-stage__viewport" ref={viewportRef}>
        {project ? (
          <div
            ref={pictureRef}
            className="video-stage__picture"
            style={{
              position: 'absolute',
              left: picture.x,
              top: picture.y,
              width: picture.width,
              height: picture.height,
            }}
            data-testid="video-stage"
            data-visible-annotation-ids={active.map((annotation) => annotation.id).join(',')}
            data-current-media-time={currentTime.toFixed(6)}
          >
            <video
              key={project.projectId}
              ref={videoRef}
              src={videoURL}
              preload="metadata"
              playsInline
              aria-label="Review video"
              style={{ width: '100%', height: '100%', display: 'block' }}
            />
            <div
              data-testid="video-picture"
              className="video-stage__overlay"
              style={{
                position: 'absolute',
                inset: 0,
                cursor: tool === 'select' ? 'default' : 'crosshair',
                touchAction: 'none',
              }}
            >
              <Stage width={picture.width} height={picture.height} onPointerDown={beginDraw}>
                <Layer clipX={0} clipY={0} clipWidth={picture.width} clipHeight={picture.height}>
                  {drawn.map((annotation) => (
                    <AnnotationShape
                      key={annotation.id}
                      annotation={preview?.id === annotation.id ? preview : annotation}
                      width={picture.width}
                      height={picture.height}
                      selectable={tool === 'select' && !recording}
                      onDown={beginMove}
                    />
                  ))}
                  {selected && tool === 'select' && !recording && (
                    <SelectionHandles
                      annotation={selected}
                      width={picture.width}
                      height={picture.height}
                      onDown={beginHandle}
                    />
                  )}
                </Layer>
              </Stage>
            </div>
          </div>
        ) : (
          <div className="video-stage__empty">
            <strong>Your next breakdown starts here.</strong>
            <span>Import a video to draw, review, and share your coaching.</span>
          </div>
        )}
      </div>
      {playbackError && (
        <div role="alert" className="video-stage__error">
          {playbackError}
        </div>
      )}
      {audioPreview.loading && (
        <div className="audio-preview-loading" role="status">
          Preparing voiceover preview…
        </div>
      )}
      <div className="video-stage__controls">
        <button
          type="button"
          aria-label={playing ? 'Pause video' : 'Play video'}
          disabled={!project || recording}
          onClick={() => {
            void togglePlayback();
          }}
        >
          {playing ? '❚❚' : '▶'}
        </button>
        <button
          type="button"
          aria-label="Step backward"
          disabled={!project || recording}
          onClick={() =>
            onSeek(clamp(currentTime - (project?.settings.seekStepSec ?? 0.1), 0, duration))
          }
        >
          −
        </button>
        <button
          type="button"
          aria-label="Step forward"
          disabled={!project || recording}
          onClick={() =>
            onSeek(clamp(currentTime + (project?.settings.seekStepSec ?? 0.1), 0, duration))
          }
        >
          +
        </button>
        <span className="video-stage__time">
          {formatMediaTime(currentTime)} <span>/ {formatMediaTime(duration)}</span>
        </span>
        <input
          className="video-stage__seek"
          aria-label="Seek video"
          type="range"
          min={0}
          max={duration || 1}
          step={0.001}
          value={Math.min(currentTime, duration)}
          disabled={!project || recording}
          onChange={(event) => onSeek(Number(event.target.value))}
        />
        <label className="video-stage__volume" title="Monitor volume">
          Vol{' '}
          <input
            aria-label="Playback volume"
            type="range"
            min={0}
            max={1}
            step={0.01}
            value={browserVolume}
            onChange={(event) => {
              const volume = Number(event.target.value);
              setBrowserVolume(volume);
            }}
          />
        </label>
      </div>
    </section>
  );
}

export default VideoStage;
