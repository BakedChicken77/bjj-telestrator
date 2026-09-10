"""Normalize untrusted microphone recordings into local, bounded PCM WAV assets."""
from __future__ import annotations

import json
import logging
import math
import os
import subprocess
import wave
from dataclasses import dataclass
from pathlib import Path

from .media import INPUT_PROTOCOLS, MediaError

log = logging.getLogger(__name__)
AUDIO_INPUT_FORMATS = 'matroska,webm,ogg,wav,mov,mp4,m4a,3gp,3g2,mj2,mp3,flac,aac'


@dataclass(frozen=True)
class NormalizedAudio:
    duration_sec: float
    codec: str = 'pcm_s16le'
    sample_rate: int = 48000
    channels: int = 1


def normalize_voiceover(source: Path, output: Path, max_duration: float) -> NormalizedAudio:
    if not math.isfinite(max_duration) or max_duration <= 0:
        raise MediaError('Position the playhead before the video ends to record commentary')
    try:
        probe = subprocess.run([os.getenv('BJJ_FFPROBE_PATH', 'ffprobe'), '-v', 'error',
                                '-protocol_whitelist', INPUT_PROTOCOLS,
                                '-format_whitelist', AUDIO_INPUT_FORMATS,
                                '-show_streams', '-of', 'json', str(source)],
                               check=True, capture_output=True, text=True, timeout=120)
        streams = json.loads(probe.stdout).get('streams', [])
        audio = next((stream for stream in streams if stream.get('codec_type') == 'audio'), None)
        if audio is None:
            raise MediaError('The recording contains no audio stream')
        stream_index = int(audio['index'])
        # Recording containers can lack duration metadata (notably MediaRecorder WebM).
        # Decode once and use the resulting bounded WAV sample count as the authority.
        max_samples = math.floor(max_duration * 48000 + 1e-7)
        if max_samples < 1:
            raise MediaError('There is no recording time remaining in the video')
        subprocess.run([os.getenv('BJJ_FFMPEG_PATH', 'ffmpeg'), '-hide_banner', '-loglevel', 'error',
                        '-nostdin', '-y', '-protocol_whitelist', INPUT_PROTOCOLS,
                        '-format_whitelist', AUDIO_INPUT_FORMATS, '-i', str(source),
                        '-map', f'0:{stream_index}', '-vn', '-af',
                        f'asetpts=PTS-STARTPTS,aresample=48000:async=1:first_pts=0,atrim=end_sample={max_samples}',
                        '-ac', '1', '-ar', '48000', '-c:a', 'pcm_s16le',
                        '-threads', os.getenv('BJJ_FFMPEG_THREADS', '2'),
                        '-t', format(max_duration, '.9f'), '-map_metadata', '-1', str(output)],
                       check=True, capture_output=True, text=True, timeout=7200)
        with wave.open(str(output), 'rb') as reader:
            frames, rate = reader.getnframes(), reader.getframerate()
            if frames < 1 or rate != 48000 or reader.getnchannels() != 1 or reader.getsampwidth() != 2:
                raise MediaError('The recording could not be normalized to a playable audio clip')
        return NormalizedAudio(duration_sec=frames / rate)
    except FileNotFoundError as exc:
        raise MediaError('FFmpeg and FFprobe must be installed to process recordings') from exc
    except (subprocess.SubprocessError, json.JSONDecodeError, ValueError, KeyError, wave.Error) as exc:
        log.exception('Voiceover normalization failed')
        log.error('Voiceover decoder detail: %s', str(getattr(exc, 'stderr', ''))[-6000:])
        output.unlink(missing_ok=True)
        raise MediaError('The recording is damaged, incomplete, or uses an unsupported audio format') from exc
