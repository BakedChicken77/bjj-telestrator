"""Geometry, interval, command, and real native FFmpeg export acceptance tests."""
from __future__ import annotations

import array
import hashlib
import json
import math
import subprocess
import threading
from pathlib import Path
from uuid import uuid4

import pytest
from PIL import Image

from app.media import probe_media
from app.models import Project
from app.renderer import (
    ExportCancelled,
    build_ffmpeg_args,
    frame_boundary,
    output_dimensions,
    render_export,
    render_overlay,
    safe_asset,
    segment_timeline,
)

STAMP = "2026-09-05T00:00:00Z"


def annotation(kind: str = "rectangle", start: float = 1, end: float = 2, **changes: object) -> dict:
    geometry = {
        "rectangle": {"x": 0.2, "y": 0.2, "width": 0.4, "height": 0.4},
        "ellipse": {"centerX": 0.4, "centerY": 0.4, "radiusX": 0.2, "radiusY": 0.2},
        "line": {"x1": 0.2, "y1": 0.4, "x2": 0.6, "y2": 0.4},
        "arrow": {"x1": 0.2, "y1": 0.4, "x2": 0.6, "y2": 0.4, "arrowheadSize": 0.1},
        "freehand": {"points": [{"x": 0.2, "y": 0.4}, {"x": 0.4, "y": 0.4}, {"x": 0.6, "y": 0.4}], "smoothing": 0},
        "text": {"x": 0.2, "y": 0.2, "text": "Guard", "fontSize": 0.15, "alignment": "left", "backgroundColor": "#000000", "backgroundOpacity": 0},
    }[kind]
    return {"id": str(uuid4()), "type": kind, "startSec": start, "endSec": end, "zIndex": 0,
            "strokeColor": "#ff0000", "strokeWidth": 0.025, "strokeOpacity": 1,
            "fillColor": "#ff0000", "fillOpacity": 1, "geometry": geometry,
            "createdAt": STAMP, "updatedAt": STAMP, **changes}


def ffmpeg(*args: str) -> None:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True, capture_output=True)


def make_source(path: Path, duration: float = 3, size: str = "160x120", audio: bool = True, mov: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    args = ["-f", "lavfi", "-i", f"color=c=0x203040:s={size}:r=30:d={duration}"]
    if audio:
        args += ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={duration}", "-c:a", "aac"]
    args += ["-c:v", "mpeg4" if mov else "libx264", "-threads", "2", "-pix_fmt", "yuv420p", "-t", str(duration), str(path)]
    ffmpeg(*args)


def make_project(source: Path, annotations: list[dict] | None = None) -> Project:
    media = probe_media(source, "source/" + source.name, source.name)
    return Project.model_validate({"schemaVersion": 1, "projectId": str(uuid4()), "projectName": "Renderer test",
                                   "createdAt": STAMP, "updatedAt": STAMP, "source": media, "proxy": media,
                                   "settings": {}, "exportSettings": {"fps": 30, "crf": 15, "preset": "ultrafast"},
                                   "annotations": annotations or [], "voiceovers": []})


def sample_frame(path: Path, frame: int, width: int, height: int) -> Image.Image:
    result = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path), "-vf", f"select=eq(n\\,{frame})", "-fps_mode", "vfr", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"], capture_output=True, check=True)
    assert len(result.stdout) == width * height * 3
    return Image.frombytes("RGB", (width, height), result.stdout)


def test_half_open_frame_segmentation() -> None:
    first = annotation("arrow", 5, 10)
    second = annotation("ellipse", 7, 9, zIndex=1)
    states = segment_timeline([first, second], 20, 30)
    assert [(s.start_frame, s.end_frame, len(s.annotation_ids)) for s in states] == [(0, 150, 0), (150, 210, 1), (210, 270, 2), (270, 300, 1), (300, 600, 0)]
    assert frame_boundary(1.001, 30) == 31
    assert frame_boundary(1, 30000 / 1001) == 30
    assert frame_boundary(89, 30) == 2670


def test_subframe_and_100_annotations() -> None:
    items = [annotation(start=i / 30, end=(i + 1) / 30, zIndex=i) for i in range(100)]
    states = segment_timeline(items, 5, 30)
    assert len(states) == 101
    assert all(len(state.annotation_ids) <= 1 for state in states)
    assert len(segment_timeline([annotation(start=0.001, end=0.002)], 1, 30)) == 1


@pytest.mark.parametrize("kind", ["rectangle", "ellipse", "line", "arrow", "freehand", "text"])
def test_renderer_geometry_and_alpha(kind: str) -> None:
    image = render_overlay([annotation(kind)], 400, 300)
    assert image.mode == "RGBA"
    assert image.getpixel((0, 0))[3] == 0
    alpha = image.getchannel("A")
    assert alpha.getbbox() is not None
    assert max(alpha.get_flattened_data()) == 255
    assert any(0 < value < 255 for value in alpha.get_flattened_data())  # actual antialiasing
    if kind != "text":
        assert image.getpixel((160, 120))[0] >= 240


def test_layer_order_and_portrait_normalization() -> None:
    back = annotation(fillColor="#00ff00")
    front = annotation(fillColor="#ff0000", zIndex=1, fillOpacity=0.5, strokeOpacity=0)
    image = render_overlay([front, back], 120, 200)
    pixel = image.getpixel((48, 80))
    assert 120 <= pixel[0] <= 135 and 120 <= pixel[1] <= 135 and pixel[3] == 255
    assert image.getpixel((100, 160))[3] == 0


def test_multiline_text_background_uses_preview_line_height() -> None:
    item = annotation("text", strokeOpacity=0,
                      geometry={"x": 0.5, "y": 0.2, "text": "Guard\nPass", "fontSize": 0.1,
                                "alignment": "center", "backgroundColor": "#00ff00", "backgroundOpacity": 1})
    image = render_overlay([item], 400, 300, supersample=1)
    box = image.getchannel("A").getbbox()
    assert box is not None
    assert box[1] == 60
    assert abs((box[3] - box[1]) - 2 * 30 * 1.2) <= 1
    assert abs((box[0] + box[2]) / 2 - 200) <= 1


def test_output_dimensions_and_safe_asset(tmp_path: Path) -> None:
    assert output_dimensions({"displayWidth": 1081, "displayHeight": 1921}) == (1080, 1920)
    source = tmp_path / "source.mp4"
    source.touch()
    assert safe_asset(tmp_path, "source.mp4") == source
    with pytest.raises(ValueError):
        safe_asset(tmp_path, "../escape.mp4")
    with pytest.raises(ValueError):
        safe_asset(tmp_path, str(source))
    with pytest.raises(FileNotFoundError):
        safe_asset(tmp_path, "missing.mp4")


def test_ffmpeg_argument_generation(tmp_path: Path) -> None:
    source = tmp_path / "source" / "input.mp4"
    make_source(source)
    project = make_project(source)
    args = build_ffmpeg_args(project, source, tmp_path / "overlay.ffconcat", tmp_path / "output.mp4")
    assert isinstance(args, list)
    assert args[args.index("-c:v") + 1] == "libx264"
    assert args[args.index("-c:a") + 1] == "aac"
    assert args[args.index("-pix_fmt") + 1] == "yuv420p"
    assert "+faststart" in args
    assert "rotate=0" in args
    assert "pipe:1" in args


@pytest.mark.integration
def test_real_export_pixels_audio_duration_and_source_preserved(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source)
    checksum = hashlib.sha256(source.read_bytes()).hexdigest()
    project = make_project(source, [annotation()])
    output = tmp_path / "exports" / "rendered.mp4"
    progress: list[float] = []
    render_export(project, tmp_path, output, tmp_path / "temp", progress.append, threading.Event())
    metadata = probe_media(output, "exports/rendered.mp4", "rendered.mp4")
    assert metadata.codec == "h264"
    assert metadata.audioCodec == "aac"
    assert metadata.displayWidth == 160 and metadata.displayHeight == 120
    assert abs(metadata.durationSec - 3) <= max(1 / 30, 0.1)
    for frame, visible in [(29, False), (30, True), (59, True), (60, False), (75, False)]:
        pixel = sample_frame(output, frame, 160, 120).getpixel((64, 48))
        assert (pixel[0] > 200 and pixel[1] < 50) == visible, (frame, pixel)
    audio = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-map", "0:a:0", "-f", "s16le", "-ac", "1", "-ar", "48000", "pipe:1"], capture_output=True, check=True).stdout
    values = array.array("h", audio)
    assert math.sqrt(sum(value * value for value in values) / len(values)) > 1000
    assert hashlib.sha256(source.read_bytes()).hexdigest() == checksum
    assert progress[-1] == 3
    assert not list((tmp_path / "temp").iterdir())


@pytest.mark.integration
@pytest.mark.parametrize("variant", ["portrait", "rotation", "silent", "mov"])
def test_real_export_orientation_and_input_variants(tmp_path: Path, variant: str) -> None:
    source = tmp_path / "source" / ("original.mov" if variant == "mov" else "original.mp4")
    make_source(source, size="120x160" if variant == "portrait" else "160x120", audio=variant != "silent", mov=variant == "mov")
    if variant == "rotation":
        rotated = source.with_name("rotated.mp4")
        ffmpeg("-i", str(source), "-c", "copy", "-metadata:s:v:0", "rotate=90", str(rotated))
        if probe_media(rotated, "source/rotated.mp4", "rotated.mp4").rotation == 0:
            # FFmpeg 6 uses the input display matrix override instead of tags.
            ffmpeg("-display_rotation:v:0", "90", "-i", str(source), "-c", "copy", str(rotated))
        rotated.replace(source)
    project = make_project(source, [annotation()])
    width, height = (120, 160) if variant in ("portrait", "rotation") else (160, 120)
    assert project.source.displayWidth == width
    output = tmp_path / "exports" / "rendered.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    metadata = probe_media(output, "exports/rendered.mp4", "rendered.mp4")
    assert (metadata.displayWidth, metadata.displayHeight) == (width, height)
    assert (metadata.codedWidth, metadata.codedHeight) == (width, height)
    assert metadata.rotation == 0
    assert metadata.hasAudio == (variant != "silent")
    pixel = sample_frame(output, 45, width, height).getpixel((round(width * 0.4), round(height * 0.4)))
    assert pixel[0] > 200 and pixel[1] < 50


def test_cancellation_cleans_partial_files(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source)
    project = make_project(source)
    cancelled = threading.Event()
    cancelled.set()
    output = tmp_path / "exports" / "rendered.mp4"
    with pytest.raises(ExportCancelled):
        render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, cancelled)
    assert not output.exists()
    assert not list((tmp_path / "temp").iterdir())


@pytest.mark.integration
def test_cancellation_terminates_running_encoder_and_cleans(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, duration=20, size="320x240")
    project = make_project(source, [annotation()])
    project.exportSettings.preset = "slow"
    cancelled = threading.Event()
    output = tmp_path / "exports" / "rendered.mp4"
    progress: list[float] = []

    def cancel_on_progress(seconds: float) -> None:
        progress.append(seconds)
        cancelled.set()

    with pytest.raises(ExportCancelled):
        render_export(project, tmp_path, output, tmp_path / "temp", cancel_on_progress, cancelled)
    assert progress
    assert not output.exists()
    assert not list((tmp_path / "temp").iterdir())


@pytest.mark.integration
def test_manual_acceptance_twenty_seconds(tmp_path: Path) -> None:
    source = tmp_path / "source" / "acceptance.mp4"
    make_source(source, duration=20)
    arrow = annotation("arrow", 5, 10)
    circle = annotation("ellipse", 7, 9, strokeColor="#ffff00", fillColor="#ffff00", zIndex=1,
                        geometry={"centerX": 0.8, "centerY": 0.7, "radiusX": 0.1, "radiusY": 0.1})
    project = make_project(source, [arrow, circle])
    output = tmp_path / "exports" / "acceptance.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    for time, red, yellow in [(4.9, False, False), (5, True, False), (7.5, True, True), (9.5, True, False), (10, False, False)]:
        frame = sample_frame(output, round(time * 30), 160, 120)
        arrow_pixel = frame.getpixel((64, 48))
        circle_pixel = frame.getpixel((128, 84))
        assert (arrow_pixel[0] > 200 and arrow_pixel[1] < 50) == red
        assert (circle_pixel[0] > 200 and circle_pixel[1] > 200) == yellow
    summary = {"durationSec": 20, "fps": 30, "checks": [4.9, 5, 7.5, 9.5, 10], "codec": "h264", "audio": "aac"}
    assert json.dumps(summary)


@pytest.mark.integration
def test_hundred_annotations_fractional_boundaries(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, duration=4, size="96x64", audio=False)
    items = [annotation(start=index / 30 + 0.001, end=(index + 1) / 30 + 0.001, zIndex=index,
                        fillColor="#ff0000" if index % 2 == 0 else "#00ff00") for index in range(100)]
    project = make_project(source, items)
    output = tmp_path / "exports" / "hundred.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    for frame, expected in [(0, None), (1, "red"), (2, "green"), (99, "red"), (100, "green"), (101, None)]:
        pixel = sample_frame(output, frame, 96, 64).getpixel((38, 25))
        if expected == "red":
            assert pixel[0] > 200 and pixel[1] < 50
        elif expected == "green":
            assert pixel[1] > 200 and pixel[0] < 50
        else:
            assert pixel[0] < 100 and pixel[1] < 100


@pytest.mark.integration
def test_export_preserves_delayed_audio_origin(tmp_path: Path) -> None:
    source = tmp_path / "source" / "delayed.mp4"
    source.parent.mkdir(parents=True)
    ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=160x120:r=30:d=3", "-itsoffset", "0.25",
           "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2.5",
           "-c:v", "libx264", "-threads", "2", "-c:a", "aac", "-t", "3", str(source))
    project = make_project(source)
    output = tmp_path / "exports" / "delayed.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    audio = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-map", "0:a:0", "-f", "s16le", "-ac", "1", "-ar", "48000", "pipe:1"], capture_output=True, check=True).stdout
    values = array.array("h", audio)
    quiet = values[:int(0.15 * 48000)]
    tone = values[int(0.4 * 48000):int(0.6 * 48000)]
    assert math.sqrt(sum(value * value for value in quiet) / len(quiet)) < 20
    assert math.sqrt(sum(value * value for value in tone) / len(tone)) > 1000


@pytest.mark.integration
def test_rotation_and_non_square_pixels_preserve_visual_quadrant(tmp_path: Path) -> None:
    source = tmp_path / "source" / "anamorphic.mp4"
    source.parent.mkdir(parents=True)
    ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=160x120:r=30:d=3",
           "-vf", "drawbox=x=0:y=0:w=80:h=60:color=red:t=fill,setsar=2/1", "-c:v", "libx264", "-threads", "2", str(source))
    rotated = source.with_name("rotation.mp4")
    ffmpeg("-i", str(source), "-c", "copy", "-metadata:s:v:0", "rotate=90", str(rotated))
    if probe_media(rotated, "source/rotation.mp4", "rotation.mp4").rotation == 0:
        ffmpeg("-display_rotation:v:0", "90", "-i", str(source), "-c", "copy", str(rotated))
    rotated.replace(source)
    project = make_project(source)
    assert (project.source.displayWidth, project.source.displayHeight) == (120, 320)
    output = tmp_path / "exports" / "rotation.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    image = sample_frame(output, 30, 120, 320)
    # Positive rotation in the display matrix is counterclockwise.
    lower_left = image.getpixel((30, 240))
    upper_left = image.getpixel((30, 80))
    assert lower_left[0] > 200 and lower_left[2] < 50
    assert upper_left[2] > 200 and upper_left[0] < 50
