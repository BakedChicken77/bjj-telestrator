"""Media inspection and deterministic display-oriented proxy generation."""
from __future__ import annotations

import json
import logging
import math
import os
import queue
import subprocess
import threading
import time
from collections.abc import Callable
from fractions import Fraction
from pathlib import Path
from typing import Any

from .color import REC709_TAGS, hdr_to_srgb, is_hdr, require_supported_color, srgb_to_rec709
from .errors import DomainError
from .models import Media

log = logging.getLogger(__name__)

# Only self-contained media inputs. Uploaded HLS/concat playlists must not resolve files or URLs.
INPUT_FORMATS = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpegts,mpeg,asf,ogg,flv,h264,hevc'
INPUT_PROTOCOLS = 'file,pipe'


class MediaError(Exception):
    pass


def check_cancelled(cancel: threading.Event | None) -> None:
    if cancel and cancel.is_set():
        raise DomainError('JOB_CANCELLED', 'Video preparation was cancelled.', 409)


def require_sdr(metadata: Media) -> None:
    # Codec alone cannot distinguish SDR HEVC from PQ/HLG/Dolby Vision.
    if metadata.transferFunction in ('smpte2084', 'arib-std-b67') or metadata.dolbyVision:
        raise DomainError('MEDIA_UNSUPPORTED', 'The prepared preview is still HDR. It cannot be used for SDR review.', 422)


def ratio(value: object, default: float = 1) -> float:
    try:
        number = float(Fraction(str(value).replace(':', '/')))
        return number if math.isfinite(number) and number > 0 else default
    except (ValueError, ZeroDivisionError):
        return default


def hdr_side_data(video: dict[str, Any]) -> list[dict[str, Any]]:
    """Preserve bounded native probe facts; the delivery policy uses a fixed peak.

    Absence means the probe did not expose static metadata, not that the source
    lacks HDR. The untouched source remains the authoritative bitstream.
    """
    result = []
    for side in video.get('side_data_list', [])[:32]:
        if not any(token in side.get('side_data_type', '').lower() for token in ('mastering', 'content light', 'dovi')):
            continue
        item = {str(key)[:100]: value for key, value in list(side.items())[:64]
                if isinstance(value, (str, int, float, bool))
                and (not isinstance(value, str) or len(value) <= 512)
                and (not isinstance(value, float) or math.isfinite(value))}
        result.append(item)
    return result


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
                     rotation=rotation, avgFrameRate=ratio(video.get('avg_frame_rate'), ratio(video.get('r_frame_rate'), 30)),
                     transferFunction=video.get('color_transfer', 'unknown'), colorPrimaries=video.get('color_primaries', 'unknown'),
                     colorMatrix=video.get('color_space', 'unknown'), colorRange=video.get('color_range', 'unknown'),
                     dolbyVision=any('DOVI' in side.get('side_data_type', '') for side in video.get('side_data_list', [])),
                     averageFrameRateRational=video.get('avg_frame_rate', '0/0'),
                     nominalFrameRateRational=video.get('r_frame_rate', '0/0'), timeBase=video.get('time_base', 'unknown'),
                     frameTimingInspection='stream-metadata', hdrMetadata={'provider': 'ffprobe', 'entries': hdr_side_data(video)})
    except (KeyError, TypeError, ValueError) as exc:
        raise MediaError('The video metadata is incomplete or invalid') from exc


def probe_media(path: Path, asset: str, original_filename: str, cancel: threading.Event | None = None) -> Media:
    process = None
    try:
        check_cancelled(cancel)
        process = subprocess.Popen([os.getenv('BJJ_FFPROBE_PATH', 'ffprobe'), '-v', 'error', '-show_streams',
                                 '-show_format', '-of', 'json', '-protocol_whitelist', INPUT_PROTOCOLS,
                                 '-format_whitelist', INPUT_FORMATS, str(path)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 120
        while True:
            check_cancelled(cancel)
            if time.monotonic() > deadline:
                raise subprocess.TimeoutExpired(process.args, 120)
            try:
                stdout, stderr = process.communicate(timeout=.1)
                break
            except subprocess.TimeoutExpired:
                continue
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, process.args, stderr=stderr)
        return parse_probe(json.loads(stdout), asset, original_filename)
    except FileNotFoundError as exc:
        raise MediaError('FFprobe is not installed or is not available on PATH') from exc
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        log.exception('FFprobe failed')
        log.error('FFprobe detail: %s', getattr(exc, 'stderr', '')[-6000:])
        raise MediaError('The video cannot be read. It may be damaged, incomplete, or unsupported') from exc
    finally:
        if process:
            from .renderer import _terminate
            _terminate(process)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()


def proxy_dimensions(metadata: Media) -> tuple[int, int]:
    factor = min(1, 1920 / max(metadata.displayWidth, metadata.displayHeight))
    return (max(2, round(metadata.displayWidth * factor / 2) * 2),
            max(2, round(metadata.displayHeight * factor / 2) * 2))


def proxy_args(source: Path, dest: Path, metadata: Media) -> list[str]:
    color = metadata.model_dump(mode='json')
    require_supported_color(color)
    width, height = proxy_dimensions(metadata)
    origin = format(metadata.videoStartSec, '.9f')
    args = [os.getenv('BJJ_FFMPEG_PATH', 'ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin',
            '-y', '-copyts', '-protocol_whitelist', INPUT_PROTOCOLS,
            '-format_whitelist', INPUT_FORMATS, '-i', str(source), '-map', f'0:{metadata.videoStreamIndex}']
    if metadata.hasAudio and metadata.audioStreamIndex is not None:
        args += ['-map', f'0:{metadata.audioStreamIndex}']
    conversion = hdr_to_srgb(color)
    delivery = ',' + srgb_to_rec709() if is_hdr(color) else ''
    args += ['-vf', f'{conversion}scale={width}:{height}:flags=lanczos,setsar=1,setpts=PTS-({origin})/TB,fps={min(30, metadata.avgFrameRate):.12g}{delivery}',
             '-af', f'asetpts=PTS-({origin})/TB,aresample=async=1:first_pts=0',
             '-c:v', 'libx264', '-preset', 'veryfast',
             '-threads', os.getenv('BJJ_FFMPEG_THREADS', '2'), '-crf', '22',
             '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k',
             '-metadata:s:v:0', 'rotate=0', '-map_metadata', '-1', '-t', str(metadata.durationSec),
             '-movflags', '+faststart', *(REC709_TAGS if is_hdr(color) else []), str(dest)]
    return args


def create_proxy(source: Path, dest: Path, metadata: Media, cancel: threading.Event | None = None,
                 progress: Callable[[float], None] = lambda _seconds: None) -> None:
    process = None
    completed = False
    reader = None
    log_path = dest.with_suffix('.ffmpeg.log')
    try:
        check_cancelled(cancel)
        args = proxy_args(source, dest, metadata)
        args[-1:-1] = ['-progress', 'pipe:1', '-nostats']
        with log_path.open('w+', encoding='utf-8') as errors:
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=errors, text=True)
            updates: queue.Queue[float] = queue.Queue(maxsize=8)
            def read_progress() -> None:
                for line in process.stdout:
                    if line.startswith('out_time_us='):
                        try:
                            updates.put_nowait(int(line.split('=', 1)[1]) / 1_000_000)
                        except (ValueError, queue.Full):
                            pass
            reader = threading.Thread(target=read_progress, daemon=True)
            reader.start()
            deadline = time.monotonic() + 7200
            while process.poll() is None:
                check_cancelled(cancel)
                if time.monotonic() > deadline:
                    raise MediaError('Preview preparation exceeded its time limit. Retry with a shorter source.')
                try:
                    seconds = updates.get(timeout=.1)
                    progress(max(0, min(metadata.durationSec, seconds)))
                except queue.Empty:
                    pass
            check_cancelled(cancel)
            reader.join(timeout=1)
            if process.returncode:
                errors.seek(max(0, errors.tell() - 8192))
                detail = errors.read()
                if 'No space left on device' in detail:
                    raise DomainError('STORAGE_LOW', 'Storage filled during preview preparation. Free space and retry.', 507)
                raise MediaError('Could not prepare the preview. Check available storage and the source file.')
        completed = True
        progress(metadata.durationSec)
    except FileNotFoundError as exc:
        raise MediaError('FFmpeg is not installed or is not available on PATH') from exc
    except subprocess.SubprocessError as exc:
        log.exception('Proxy generation failed')
        log.error('FFmpeg detail: %s', getattr(exc, 'stderr', '')[-6000:])
        dest.unlink(missing_ok=True)
        raise MediaError('Could not create the editing video. Check free disk space and the source file') from exc
    finally:
        if process:
            from .renderer import _terminate
            _terminate(process)
            if reader:
                reader.join(timeout=1)
            if process.stdout:
                process.stdout.close()
        log_path.unlink(missing_ok=True)
        if not completed:
            dest.unlink(missing_ok=True)
