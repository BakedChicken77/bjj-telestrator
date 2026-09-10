"""Media inspection and deterministic display-oriented proxy generation."""
from __future__ import annotations

import json
import logging
import math
import os
import subprocess
from fractions import Fraction
from pathlib import Path
from typing import Any

from .models import Media

log = logging.getLogger(__name__)

# Only self-contained media inputs. Uploaded HLS/concat playlists must not resolve files or URLs.
INPUT_FORMATS = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpegts,mpeg,asf,ogg,flv,h264,hevc'
INPUT_PROTOCOLS = 'file,pipe'


class MediaError(Exception):
    pass


def ratio(value: object, default: float = 1) -> float:
    try:
        number = float(Fraction(str(value).replace(':', '/')))
        return number if math.isfinite(number) and number > 0 else default
    except (ValueError, ZeroDivisionError):
        return default


def parse_probe(data: dict[str, Any], asset: str, original_filename: str) -> Media:
    video = next((v for v in data.get('streams', []) if v.get('codec_type') == 'video'
                  and not v.get('disposition', {}).get('attached_pic')), None)
    audio = next((v for v in data.get('streams', []) if v.get('codec_type') == 'audio'), None)
    if not video:
        raise MediaError('The uploaded file does not contain a playable video stream')
    try:
        width, height = int(video['width']), int(video['height'])
        duration = float(video.get('duration') or data.get('format', {}).get('duration') or 0)
        if not math.isfinite(duration) or duration <= 0 or width <= 0 or height <= 0:
            raise ValueError()
        rotation = float(video.get('tags', {}).get('rotate', 0))
        for side in video.get('side_data_list', []):
            if 'rotation' in side:
                rotation = float(side['rotation'])
        rotation %= 360
        # Non-quarter-turn display matrices need a different spatial contract.
        if abs(rotation / 90 - round(rotation / 90)) > 0.01:
            raise MediaError('Videos with non-right-angle rotation metadata are unsupported')
        rotation = float(round(rotation / 90) * 90 % 360)
        sar = ratio(video.get('sample_aspect_ratio', '1:1'))
        display_width, display_height = max(1, round(width * sar)), height
        if rotation in (90, 270):
            display_width, display_height = display_height, display_width
        return Media(asset=asset, originalFilename=original_filename, durationSec=duration,
                     videoStartSec=float(video.get('start_time') or 0),
                     videoStreamIndex=int(video.get('index', 0)),
                     audioStreamIndex=int(audio.get('index', 1)) if audio else None,
                     codec=video.get('codec_name', 'unknown'),
                     audioCodec=audio.get('codec_name') if audio else None, hasAudio=audio is not None,
                     codedWidth=width, codedHeight=height,
                     displayWidth=display_width, displayHeight=display_height,
                     sampleAspectRatio=video.get('sample_aspect_ratio', '1:1'),
                     displayAspectRatio=video.get('display_aspect_ratio', f'{display_width}:{display_height}'),
                     rotation=rotation, avgFrameRate=ratio(video.get('avg_frame_rate'), ratio(video.get('r_frame_rate'), 30)))
    except (KeyError, TypeError, ValueError) as exc:
        raise MediaError('The video metadata is incomplete or invalid') from exc


def probe_media(path: Path, asset: str, original_filename: str) -> Media:
    try:
        result = subprocess.run([os.getenv('BJJ_FFPROBE_PATH', 'ffprobe'), '-v', 'error', '-show_streams',
                                 '-show_format', '-of', 'json', '-protocol_whitelist', INPUT_PROTOCOLS,
                                 '-format_whitelist', INPUT_FORMATS, str(path)],
                                capture_output=True, text=True, check=True, timeout=120)
        return parse_probe(json.loads(result.stdout), asset, original_filename)
    except FileNotFoundError as exc:
        raise MediaError('FFprobe is not installed or is not available on PATH') from exc
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        log.exception('FFprobe failed')
        log.error('FFprobe detail: %s', getattr(exc, 'stderr', '')[-6000:])
        raise MediaError('The video cannot be read. It may be damaged, incomplete, or unsupported') from exc


def proxy_dimensions(metadata: Media) -> tuple[int, int]:
    factor = min(1, 1920 / max(metadata.displayWidth, metadata.displayHeight))
    return (max(2, round(metadata.displayWidth * factor / 2) * 2),
            max(2, round(metadata.displayHeight * factor / 2) * 2))


def proxy_args(source: Path, dest: Path, metadata: Media) -> list[str]:
    width, height = proxy_dimensions(metadata)
    origin = format(metadata.videoStartSec, '.9f')
    args = [os.getenv('BJJ_FFMPEG_PATH', 'ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin',
            '-y', '-copyts', '-protocol_whitelist', INPUT_PROTOCOLS,
            '-format_whitelist', INPUT_FORMATS, '-i', str(source), '-map', f'0:{metadata.videoStreamIndex}']
    if metadata.hasAudio and metadata.audioStreamIndex is not None:
        args += ['-map', f'0:{metadata.audioStreamIndex}']
    args += ['-vf', f'scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-({origin})/TB',
             '-af', f'asetpts=PTS-({origin})/TB,aresample=async=1:first_pts=0',
             '-c:v', 'libx264', '-preset', 'veryfast',
             '-threads', os.getenv('BJJ_FFMPEG_THREADS', '2'), '-crf', '22',
             '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k',
             '-metadata:s:v:0', 'rotate=0', '-map_metadata', '-1', '-t', str(metadata.durationSec),
             '-movflags', '+faststart', str(dest)]
    return args


def create_proxy(source: Path, dest: Path, metadata: Media) -> None:
    try:
        subprocess.run(proxy_args(source, dest, metadata), capture_output=True, text=True,
                       check=True, timeout=7200)
    except FileNotFoundError as exc:
        raise MediaError('FFmpeg is not installed or is not available on PATH') from exc
    except subprocess.SubprocessError as exc:
        log.exception('Proxy generation failed')
        log.error('FFmpeg detail: %s', getattr(exc, 'stderr', '')[-6000:])
        dest.unlink(missing_ok=True)
        raise MediaError('Could not create the editing video. Check free disk space and the source file') from exc
