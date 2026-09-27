"""Audio graph and actual AAC mix verification after the Milestone 1 gate."""
from __future__ import annotations

import array
import math
import subprocess
import threading
from pathlib import Path
from uuid import uuid4

import pytest

from app.media import probe_media
from app.models import Project, Voiceover
from app.renderer import audible_voiceovers, build_audio_mix_graph, build_ffmpeg_args, render_export
from test_renderer import STAMP, ffmpeg, make_project, make_source

RATE = 48000


def voiceover(project_dir: Path, frequency: int = 880, start: float = 1, duration: float = 1, **changes: object) -> Voiceover:
    identifier = str(uuid4())
    path = project_dir / "voiceover" / f"{identifier}.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg("-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate={RATE}:duration={duration}",
           "-c:a", "pcm_s16le", "-ac", "1", str(path))
    return Voiceover.model_validate({"id": identifier, "asset": f"voiceover/{identifier}.wav", "startSec": start,
                                    "durationSec": duration, "endSec": start + duration, "gain": 1, "muted": False,
                                    "timingOffsetMs": 0, "recordedAt": STAMP, "codec": "pcm_s16le", "sampleRate": RATE,
                                    "channels": 1, **changes})


def export_samples(project: Project, project_dir: Path) -> tuple[Path, array.array]:
    output = project_dir / "exports" / f"{uuid4()}.mp4"
    render_export(project, project_dir, output, project_dir / "temp", lambda _: None, threading.Event())
    result = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-map", "0:a:0", "-f", "f32le", "-ac", "1", "-ar", str(RATE), "pipe:1"], capture_output=True, check=True)
    return output, array.array("f", result.stdout)


def amplitude(samples: array.array, start: float, end: float, frequency: int) -> float:
    window = samples[round(start * RATE):round(end * RATE)]
    real = sum(value * math.cos(2 * math.pi * frequency * index / RATE) for index, value in enumerate(window))
    imaginary = sum(value * math.sin(2 * math.pi * frequency * index / RATE) for index, value in enumerate(window))
    return 2 * math.hypot(real, imaginary) / len(window)


def rms(samples: array.array, start: float, end: float) -> float:
    window = samples[round(start * RATE):round(end * RATE)]
    return math.sqrt(sum(value * value for value in window) / len(window))


def test_audio_graph_has_sample_delays_gains_trim_and_no_normalization(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source)
    project = make_project(source)
    project.settings.originalAudioGain = 0.25
    project.settings.voiceoverMasterGain = 0.5
    clip = voiceover(tmp_path, timingOffsetMs=125, gain=0.4)
    project.voiceovers = [clip]
    graph = build_audio_mix_graph(project, audible_voiceovers(project))
    assert "volume=0.25[original]" in graph
    assert "volume=0.2,adelay=54000S:all=1" in graph
    assert "atrim=duration=1,asetpts=PTS-STARTPTS" in graph
    assert "amix=inputs=2:duration=longest:dropout_transition=0:normalize=0" in graph
    assert "alimiter=limit=0.98:level=0:latency=1" in graph
    assert "apad=whole_dur=3,atrim=duration=3" in graph
    args = build_ffmpeg_args(project, source, tmp_path / "overlay.ffconcat", tmp_path / "output.mp4", tmp_path)
    voice_input = args.index(str(tmp_path / clip.asset))
    assert args[voice_input - 3:voice_input] == ["-format_whitelist", "wav", "-i"]


def test_muted_zero_gain_and_safe_asset_behavior(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, audio=False)
    project = make_project(source)
    project.voiceovers = [voiceover(tmp_path, muted=True), voiceover(tmp_path, gain=0)]
    assert audible_voiceovers(project) == []
    assert build_audio_mix_graph(project, []) == ""
    project.voiceovers[0].muted = False
    project.settings.voiceoverMasterGain = 0
    assert audible_voiceovers(project) == []
    project.settings.voiceoverMasterGain = 1
    project.voiceovers[0].asset = "../escape.wav"
    with pytest.raises(ValueError, match="asset"):
        build_ffmpeg_args(project, source, tmp_path / "timeline", tmp_path / "out.mp4", tmp_path)


@pytest.mark.integration
def test_voiceover_nudge_original_gain_and_aac_timeline(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, duration=4)
    project = make_project(source)
    project.settings.originalAudioGain = 0.25
    project.settings.voiceoverMasterGain = 0.5
    project.voiceovers = [voiceover(tmp_path, start=1, duration=1, timingOffsetMs=125, gain=0.5)]
    output, samples = export_samples(project, tmp_path)
    metadata = probe_media(output, "exports/result.mp4", "result.mp4")
    assert metadata.audioCodec == "aac" and metadata.codec == "h264"
    assert abs(metadata.durationSec - 4) <= 1 / 30
    assert abs(len(samples) / RATE - 4) < 0.03
    assert amplitude(samples, 0.3, 0.5, 440) > 0.01
    assert amplitude(samples, 0.3, 0.5, 880) < 0.0002
    assert amplitude(samples, 1.02, 1.1, 880) < 0.0002
    voice_level = amplitude(samples, 1.3, 1.5, 880)
    source_level = amplitude(samples, 1.3, 1.5, 440)
    assert voice_level > 0.01
    assert 0.85 < voice_level / source_level < 1.15
    assert amplitude(samples, 2.3, 2.5, 880) < 0.0002
    assert amplitude(samples, 2.3, 2.5, 440) > 0.01


@pytest.mark.integration
def test_overlapping_voices_sum_and_original_mute(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, duration=4)
    project = make_project(source)
    project.settings.originalAudioMuted = True
    project.voiceovers = [voiceover(tmp_path, frequency=880, start=0.5, duration=2),
                          voiceover(tmp_path, frequency=1320, start=1.5, duration=1)]
    _, samples = export_samples(project, tmp_path)
    assert rms(samples, 0.1, 0.3) < 0.0001
    first_alone = amplitude(samples, 0.8, 1, 880)
    first_overlapped = amplitude(samples, 1.8, 2, 880)
    assert first_alone > 0.04
    assert 0.95 < first_overlapped / first_alone < 1.05
    assert amplitude(samples, 1.8, 2, 1320) > 0.04
    assert amplitude(samples, 1.8, 2, 440) < 0.0003
    assert rms(samples, 2.8, 3) < 0.0001


@pytest.mark.integration
def test_silent_source_voice_only_and_muted_clips(tmp_path: Path) -> None:
    source = tmp_path / "source" / "original.mp4"
    make_source(source, duration=4, audio=False)
    project = make_project(source)
    project.voiceovers = [voiceover(tmp_path, frequency=880, start=1, duration=1),
                          voiceover(tmp_path, frequency=1320, start=1, duration=1, muted=True),
                          voiceover(tmp_path, frequency=1760, start=1, duration=1, gain=0)]
    _, samples = export_samples(project, tmp_path)
    assert rms(samples, 0.2, 0.4) < 0.0001
    assert amplitude(samples, 1.2, 1.4, 880) > 0.04
    assert amplitude(samples, 1.2, 1.4, 1320) < 0.0003
    assert amplitude(samples, 1.2, 1.4, 1760) < 0.0003
    assert rms(samples, 2.4, 2.6) < 0.0001
    project.settings.voiceoverMasterGain = 0
    output = tmp_path / "exports" / "all-muted.mp4"
    render_export(project, tmp_path, output, tmp_path / "temp", lambda _: None, threading.Event())
    assert not probe_media(output, "exports/all-muted.mp4", "all-muted.mp4").hasAudio
