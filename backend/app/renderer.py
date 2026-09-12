"""Deterministic, frame-accurate native FFmpeg annotation export.

An annotation boundary maps to ceil(seconds * output_fps). Each interval has
one transparent PNG, so static drawings are rasterized once per active state.
FFconcat's per-file frame rate keeps image timestamps on the output frame grid.
"""

from __future__ import annotations

import json
import logging
import math
import os
import queue
import subprocess
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

from PIL import Image, ImageDraw, ImageFont

from .media import INPUT_FORMATS, INPUT_PROTOCOLS
from .storage import StorageError, asset_path

if TYPE_CHECKING:
    from .models import Project

logger = logging.getLogger(__name__)


class ExportCancelled(Exception):
    """Raised after a cancelled encoder and its output have been cleaned up."""


@dataclass(frozen=True)
class OverlayInterval:
    start_frame: int
    end_frame: int
    annotation_ids: tuple[str, ...]


def _document(value: Any) -> dict[str, Any]:
    return value.model_dump() if hasattr(value, "model_dump") else value


def frame_boundary(seconds: float, fps: float) -> int:
    """First output frame on which a half-open boundary takes effect."""
    return math.ceil(seconds * fps - 1e-8)


def segment_timeline(
    annotations: Sequence[Any], duration: float, fps: float
) -> list[OverlayInterval]:
    """Merge equal adjacent states; annotations shorter than a frame may vanish."""
    end_frame = frame_boundary(duration, fps)
    items = sorted((_document(item) for item in annotations), key=lambda item: item["zIndex"])
    events = {0, end_frame}
    for item in items:
        events.add(min(end_frame, max(0, frame_boundary(item["startSec"], fps))))
        events.add(min(end_frame, max(0, frame_boundary(item["endSec"], fps))))
    boundaries = sorted(events)
    result: list[OverlayInterval] = []
    for start, end in zip(boundaries, boundaries[1:], strict=False):
        active = tuple(
            item["id"]
            for item in items
            if frame_boundary(item["startSec"], fps) <= start
            < frame_boundary(item["endSec"], fps)
        )
        if result and result[-1].annotation_ids == active:
            previous = result.pop()
            result.append(OverlayInterval(previous.start_frame, end, active))
        else:
            result.append(OverlayInterval(start, end, active))
    return result


def output_dimensions(source: Any) -> tuple[int, int]:
    """Use square pixels and source display orientation; H.264 requires even size."""
    metadata = _document(source)
    return (
        max(2, int(round(metadata["displayWidth"] / 2)) * 2),
        max(2, int(round(metadata["displayHeight"] / 2)) * 2),
    )


def font_path() -> Path:
    candidates = [
        Path(os.environ.get("BJJ_FONT_PATH", "/nonexistent")),
        Path(__file__).resolve().parents[2] / "assets" / "DejaVuSans.ttf",
        Path("/app/assets/DejaVuSans.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError("The bundled DejaVu Sans font is missing. Rebuild the application image.")


def _rgba(color: str, opacity: float) -> tuple[int, int, int, int]:
    return (int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16), round(opacity * 255))


def _annotation_layer(
    item: dict[str, Any], width: int, height: int, font: Path
) -> tuple[Image.Image, tuple[int, int]]:
    """Rasterize to a cropped layer so work scales with annotation area."""
    geometry = item["geometry"]
    kind = item["type"]
    unit = min(width, height)
    thickness = max(1, round(item["strokeWidth"] * unit))
    stroke = _rgba(item["strokeColor"], item["strokeOpacity"])
    fill = _rgba(item.get("fillColor", "#ffffff"), item.get("fillOpacity", 0))
    points: list[tuple[float, float]] = []
    text_font: ImageFont.FreeTypeFont | None = None
    text_origin = (0.0, 0.0)
    text_size = (0.0, 0.0)
    if kind in ("line", "arrow"):
        points = [(geometry["x1"] * width, geometry["y1"] * height), (geometry["x2"] * width, geometry["y2"] * height)]
        if kind == "arrow":
            tail, tip = points
            angle = math.atan2(tip[1] - tail[1], tip[0] - tail[0])
            size = geometry["arrowheadSize"] * unit
            # Matches Konva pointerLength / pointerWidth (width = size).
            base = (tip[0] - size * math.cos(angle), tip[1] - size * math.sin(angle))
            points += [(base[0] - size / 2 * math.sin(angle), base[1] + size / 2 * math.cos(angle)), (base[0] + size / 2 * math.sin(angle), base[1] - size / 2 * math.cos(angle))]
    elif kind == "rectangle":
        points = [(geometry["x"] * width, geometry["y"] * height), ((geometry["x"] + geometry["width"]) * width, (geometry["y"] + geometry["height"]) * height)]
    elif kind == "ellipse":
        points = [((geometry["centerX"] - geometry["radiusX"]) * width, (geometry["centerY"] - geometry["radiusY"]) * height), ((geometry["centerX"] + geometry["radiusX"]) * width, (geometry["centerY"] + geometry["radiusY"]) * height)]
    elif kind == "freehand":
        points = [(point["x"] * width, point["y"] * height) for point in geometry["points"]]
    elif kind == "text":
        text_font = ImageFont.truetype(str(font), max(1, round(geometry["fontSize"] * unit)))
        lines = geometry["text"].split("\n")
        text_width = max(text_font.getlength(line) for line in lines)
        line_height = geometry["fontSize"] * unit * 1.2
        text_size = (text_width, line_height * len(lines))
        anchor = {"left": 0, "center": 0.5, "right": 1}[geometry["alignment"]]
        text_origin = (geometry["x"] * width - anchor * text_width, geometry["y"] * height)
        points = [text_origin, (text_origin[0] + text_size[0], text_origin[1] + text_size[1])]
    else:
        raise ValueError(f"Unsupported annotation type: {kind}")
    pad = thickness + 3
    left = max(0, math.floor(min(point[0] for point in points) - pad))
    top = max(0, math.floor(min(point[1] for point in points) - pad))
    right = min(width, math.ceil(max(point[0] for point in points) + pad))
    bottom = min(height, math.ceil(max(point[1] for point in points) + pad))
    layer = Image.new("RGBA", (max(1, right - left), max(1, bottom - top)))
    draw = ImageDraw.Draw(layer)
    local = [(x - left, y - top) for x, y in points]
    if kind in ("line", "arrow", "freehand"):
        line = local[:2] if kind == "arrow" else local
        draw.line(line, fill=stroke, width=thickness, joint="curve")
        radius = thickness / 2
        for x, y in (line[0], line[-1]):
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=stroke)
        if kind == "arrow":
            draw.polygon([local[1], local[2], local[3]], fill=stroke)
    elif kind in ("rectangle", "ellipse"):
        # Separate layers preserve fill/stroke alpha blending at the border.
        shape = draw.rectangle if kind == "rectangle" else draw.ellipse
        shape([local[0], local[1]], fill=fill)
        border = Image.new("RGBA", layer.size)
        border_draw = ImageDraw.Draw(border)
        border_shape = border_draw.rectangle if kind == "rectangle" else border_draw.ellipse
        half = thickness / 2
        box = (local[0][0] - half, local[0][1] - half, local[1][0] + half, local[1][1] + half)
        border_shape(box, outline=stroke, width=thickness)
        layer.alpha_composite(border)
    elif kind == "text" and text_font is not None:
        x, y = text_origin[0] - left, text_origin[1] - top
        draw.rectangle((x, y, x + text_size[0], y + text_size[1]), fill=_rgba(geometry.get("backgroundColor", "#000000"), geometry.get("backgroundOpacity", 0)))
        lettering = Image.new("RGBA", layer.size)
        lettering_draw = ImageDraw.Draw(lettering)
        # Browser Canvas / Konva places text at its line box; use ascent baseline.
        ascent, descent = text_font.getmetrics()
        line_height = geometry["fontSize"] * unit * 1.2
        baseline = y + (line_height - ascent - descent) / 2 + ascent
        for index, line in enumerate(geometry["text"].split("\n")):
            offset = {"left": 0, "center": 0.5, "right": 1}[geometry["alignment"]] * (text_size[0] - text_font.getlength(line))
            lettering_draw.text((x + offset, baseline + index * line_height), line, font=text_font, fill=stroke, anchor="ls")
        layer.alpha_composite(lettering)
    return layer, (left, top)


def render_overlay(
    annotations: Sequence[Any], width: int, height: int, supersample: int = 2
) -> Image.Image:
    """Render clipped normalized geometry with two-times spatial antialiasing."""
    canvas = Image.new("RGBA", (width * supersample, height * supersample))
    font = font_path()
    for annotation in sorted((_document(item) for item in annotations), key=lambda item: item["zIndex"]):
        layer, origin = _annotation_layer(annotation, canvas.width, canvas.height, font)
        canvas.alpha_composite(layer, origin)
    return canvas.resize((width, height), Image.Resampling.LANCZOS) if supersample > 1 else canvas


def write_overlay_timeline(
    project: Any, temp_dir: Path, cancel_event: threading.Event
) -> Path:
    document = _document(project)
    fps = document["exportSettings"]["fps"]
    width, height = output_dimensions(document["source"])
    states = segment_timeline(document["annotations"], document["source"]["durationSec"], fps)
    annotations = {item["id"]: item for item in document["annotations"]}
    cache: dict[tuple[str, ...], str] = {}
    manifest = ["ffconcat version 1.0"]
    for interval in states:
        if cancel_event.is_set():
            raise ExportCancelled()
        if interval.annotation_ids not in cache:
            name = f"overlay-{len(cache):05d}.png"
            render_overlay([annotations[key] for key in interval.annotation_ids], width, height).save(temp_dir / name, compress_level=1)
            cache[interval.annotation_ids] = name
        name = cache[interval.annotation_ids]
        manifest += [f"file '{name}'", f"option framerate {fps:.12g}", f"duration {(interval.end_frame - interval.start_frame) / fps:.12f}"]
    # The demuxer needs a final packet to establish the preceding duration.
    manifest += [f"file '{cache[states[-1].annotation_ids]}'", f"option framerate {fps:.12g}"]
    destination = temp_dir / "overlay.ffconcat"
    destination.write_text("\n".join(manifest) + "\n", encoding="utf-8")
    return destination


def safe_asset(project_dir: Path, asset: str) -> Path:
    """Defense in depth: renderers never resolve client assets outside a project."""
    try:
        candidate = asset_path(project_dir, asset)
    except StorageError as exc:
        raise ValueError("Invalid project asset reference.") from exc
    if not candidate.is_file():
        raise FileNotFoundError("A source media asset is missing.")
    return candidate


def audible_voiceovers(project: Any) -> list[dict[str, Any]]:
    """Muted and zero-gain clips do not need a decoder or an output audio track."""
    document = _document(project)
    master = document["settings"].get("voiceoverMasterGain", 1)
    return [clip for clip in document.get("voiceovers", []) if not clip["muted"] and clip["gain"] * master > 0]


def build_audio_mix_graph(project: Any, clips: Sequence[dict[str, Any]]) -> str:
    """Sum tracks at explicit gains, with sample-accurate placement and a limiter.

    The 0.98 peak limiter has no makeup gain and compensates its lookahead delay.
    Ordinary-level tracks are unchanged; clipping peaks are reduced. There is no
    automatic ducking or amix normalization when other clips start or finish.
    """
    document = _document(project)
    duration = document["source"]["durationSec"]
    settings = document["settings"]
    filters: list[str] = []
    labels: list[str] = []
    audio_format = "aresample=48000:async=1:first_pts=0,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
    if document["source"]["hasAudio"]:
        stream = document["source"].get("audioStreamIndex")
        origin = document["source"].get("videoStartSec", 0)
        selector = f"0:{stream}" if stream is not None else "0:a:0"
        gain = 0 if settings.get("originalAudioMuted", False) else settings.get("originalAudioGain", 1)
        filters.append(f"[{selector}]asetpts=PTS-({origin:.12g})/TB,{audio_format},volume={gain:.12g}[original]")
        labels.append("[original]")
    for index, clip in enumerate(clips):
        gain = clip["gain"] * settings.get("voiceoverMasterGain", 1)
        start = clip["startSec"] + clip.get("timingOffsetMs", 0) / 1000
        delay_samples = round(start * 48000)
        label = f"voice{index}"
        filters.append(f"[{index + 2}:a:0]atrim=duration={clip['durationSec']:.12g},asetpts=PTS-STARTPTS,{audio_format},volume={gain:.12g},adelay={delay_samples}S:all=1[{label}]")
        labels.append(f"[{label}]")
    if not labels:
        return ""
    source_label = labels[0]
    if len(labels) > 1:
        filters.append("".join(labels) + f"amix=inputs={len(labels)}:duration=longest:dropout_transition=0:normalize=0[summed]")
        source_label = "[summed]"
    filters.append(f"{source_label}alimiter=limit=0.98:level=0:latency=1,apad=whole_dur={duration:.12g},atrim=duration={duration:.12g},asetpts=N/SR/TB[a]")
    return ";".join(filters)


def build_ffmpeg_args(
    project: Any, source: Path, manifest: Path, output: Path, project_dir: Path | None = None
) -> list[str]:
    document = _document(project)
    settings = document["exportSettings"]
    width, height = output_dimensions(document["source"])
    fps = settings["fps"]
    origin = document["source"].get("videoStartSec", 0)
    video_stream = document["source"].get("videoStreamIndex", 0)
    graph = (
        f"[0:{video_stream}]setpts=PTS-({origin:.12g})/TB,scale={width}:{height}:flags=lanczos,setsar=1,fps={fps:.12g}[base];"
        "[1:v:0]setpts=PTS-STARTPTS[annotations];"
        "[base][annotations]overlay=0:0:format=auto:eof_action=repeat:repeatlast=1,format=yuv420p[v]"
    )
    threads = str(max(1, int(os.environ.get("BJJ_FFMPEG_THREADS", "2"))))
    command = [os.environ.get("BJJ_FFMPEG_PATH", "ffmpeg"), "-hide_banner", "-y", "-nostdin", "-loglevel", "error", "-copyts", "-filter_complex_threads", "1", "-threads", threads, "-protocol_whitelist", INPUT_PROTOCOLS, "-format_whitelist", INPUT_FORMATS, "-i", str(source), "-f", "concat", "-safe", "0", "-i", str(manifest)]
    clips = audible_voiceovers(document)
    for clip in clips:
        if project_dir is None:
            raise ValueError("A project directory is required to resolve voiceover assets.")
        clip_path = safe_asset(project_dir, clip["asset"])
        command += ["-protocol_whitelist", INPUT_PROTOCOLS, "-format_whitelist", "wav", "-i", str(clip_path)]
    audio_graph = build_audio_mix_graph(document, clips)
    if audio_graph:
        graph += ";" + audio_graph
    command += ["-filter_complex", graph, "-map", "[v]"]
    if audio_graph:
        command += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
    command += ["-c:v", "libx264", "-threads", threads, "-preset", settings["preset"], "-crf", str(settings["crf"]), "-pix_fmt", "yuv420p", "-r", f"{fps:.12g}", "-t", f"{document['source']['durationSec']:.12f}", "-metadata:s:v:0", "rotate=0", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", str(output)]
    return command


def _terminate(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def render_export(
    project: Project,
    project_dir: Path,
    output: Path,
    temp_dir: Path,
    on_progress: Callable[[float], None],
    cancel_event: threading.Event,
) -> None:
    """Render a validated immutable snapshot. Progress reports encoded seconds."""
    source = safe_asset(project_dir, project.source.asset)
    temp_dir.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    process: subprocess.Popen[str] | None = None
    completed = False
    try:
        if cancel_event.is_set():
            raise ExportCancelled()
        manifest = write_overlay_timeline(project, temp_dir, cancel_event)
        args = build_ffmpeg_args(project, source, manifest, output, project_dir)
        logger.info(json.dumps({"event": "export_encoder_start", "projectId": project.projectId, "states": len(list(temp_dir.glob("overlay-*.png")))}))
        progress_lines: queue.Queue[str | None] = queue.Queue()
        with (temp_dir / "ffmpeg.log").open("w+", encoding="utf-8") as log:
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)

            def read_progress() -> None:
                assert process is not None and process.stdout is not None
                for line in process.stdout:
                    progress_lines.put(line)
                progress_lines.put(None)

            reader = threading.Thread(target=read_progress, daemon=True)
            reader.start()
            while True:
                if cancel_event.is_set():
                    _terminate(process)
                    raise ExportCancelled()
                try:
                    line = progress_lines.get(timeout=0.1)
                except queue.Empty:
                    continue
                if line is None:
                    break
                if line.startswith("out_time_us="):
                    try:
                        on_progress(min(project.source.durationSec, max(0, int(line.split("=", 1)[1]) / 1_000_000)))
                    except ValueError:
                        pass
            code = process.wait()
            reader.join(timeout=1)
            if cancel_event.is_set():
                raise ExportCancelled()
            if code:
                log.seek(0)
                detail = log.read()[-12000:]
                logger.error(json.dumps({"event": "export_encoder_failed", "code": code, "detail": detail}))
                if "No space left on device" in detail:
                    from .errors import DomainError
                    raise DomainError("STORAGE_LOW", "Storage filled during export. Free space and retry this revision.", 507)
                raise RuntimeError("FFmpeg could not render this video. Check the backend logs for details.")
        if not output.is_file() or output.stat().st_size == 0:
            raise RuntimeError("The encoder did not create an output video.")
        on_progress(project.source.durationSec)
        completed = True
    finally:
        if process is not None:
            _terminate(process)
            if process.stdout is not None:
                process.stdout.close()
        if not completed:
            output.unlink(missing_ok=True)
        for path in temp_dir.glob("overlay-*.png"):
            path.unlink(missing_ok=True)
        (temp_dir / "overlay.ffconcat").unlink(missing_ok=True)
        (temp_dir / "ffmpeg.log").unlink(missing_ok=True)
