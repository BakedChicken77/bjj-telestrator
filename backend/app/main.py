"""Single-user local API and compiled frontend host."""
from __future__ import annotations

import errno
import json
import logging
import math
import os
import shutil
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated
from urllib.parse import urlsplit
from uuid import uuid4

from fastapi import FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .config import Config
from .jobs import JobManager
from .media import MediaError, create_proxy, probe_media
from .models import Job, Project, Voiceover
from .storage import ProjectStore, StorageError, asset_path, safe_filename, utc_now
from .voiceover import normalize_voiceover


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {'time': utc_now(), 'level': record.levelname,
                                      'logger': record.name, 'message': record.getMessage()}
        for key in ('projectId', 'jobId'):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload['exception'] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.getLogger('app').addHandler(handler)
logging.getLogger('app').setLevel(logging.INFO)
log = logging.getLogger(__name__)


class LocalRequestGuard:
    """Reject DNS rebinding, cross-origin writes, and oversized streaming bodies."""
    def __init__(self, app: ASGIApp, config: Config):
        self.app, self.config = app, config

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope['type'] != 'http':
            await self.app(scope, receive, send)
            return
        headers = dict(scope['headers'])
        host = headers.get(b'host', b'').decode('latin1')
        try:
            hostname = urlsplit('http://' + host).hostname
        except ValueError:
            hostname = None
        if hostname not in ('localhost', '127.0.0.1', '::1'):
            await JSONResponse({'detail': 'Only local requests are permitted'}, status_code=400)(scope, receive, send)
            return
        origin = headers.get(b'origin', b'').decode('latin1')
        if (scope['method'] not in ('GET', 'HEAD', 'OPTIONS') and origin
                and origin != f"{scope.get('scheme', 'http')}://{host}"
                and origin not in self.config.allowed_origins):
            await JSONResponse({'detail': 'This request origin is not allowed'}, status_code=403)(scope, receive, send)
            return
        limit = self.config.max_upload_bytes + 1024 * 1024
        if scope['method'] == 'POST' and scope['path'].endswith('/voiceovers'):
            limit = min(self.config.max_voiceover_bytes, self.config.max_upload_bytes) + 1024 * 1024
        try:
            declared_size = int(headers.get(b'content-length', b'0'))
        except ValueError:
            declared_size = limit + 1
        if declared_size > limit:
            await JSONResponse({'detail': 'Upload exceeds the configured size limit'}, status_code=413)(scope, receive, send)
            return
        received = 0

        async def limited_receive() -> Message:
            nonlocal received
            message = await receive()
            received += len(message.get('body', b''))
            if received > limit:
                raise HTTPException(413, 'Upload exceeds the configured size limit')
            return message

        await self.app(scope, limited_receive, send)


def create_app(config: Config | None = None) -> FastAPI:
    settings = config or Config()
    store = ProjectStore(settings.data_dir)

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        application.state.jobs = JobManager(store, settings.export_workers)
        yield
        await run_in_threadpool(application.state.jobs.close)

    application = FastAPI(title='BJJ Telestrator', version='1.0.0', lifespan=lifespan)
    application.state.store = store
    application.state.config = settings
    application.add_middleware(LocalRequestGuard, config=settings)

    @application.exception_handler(StorageError)
    async def storage_error(_request: Request, exc: StorageError) -> JSONResponse:
        return JSONResponse({'detail': str(exc)}, status_code=400)

    @application.exception_handler(MediaError)
    async def media_error(_request: Request, exc: MediaError) -> JSONResponse:
        return JSONResponse({'detail': str(exc)}, status_code=422)

    @application.exception_handler(FileNotFoundError)
    async def missing_error(_request: Request, _exc: FileNotFoundError) -> JSONResponse:
        return JSONResponse({'detail': 'Project, job, or media asset was not found'}, status_code=404)

    @application.exception_handler(OSError)
    async def os_error(_request: Request, exc: OSError) -> JSONResponse:
        log.exception('Filesystem operation failed', exc_info=exc)
        detail = 'Insufficient disk space' if exc.errno == errno.ENOSPC else 'Could not access project storage'
        return JSONResponse({'detail': detail}, status_code=507 if exc.errno == errno.ENOSPC else 500)

    @application.exception_handler(Exception)
    async def unexpected_error(_request: Request, exc: Exception) -> JSONResponse:
        log.exception('Request failed', exc_info=exc)
        return JSONResponse({'detail': 'The operation failed. See backend logs for details.'}, status_code=500)

    @application.get('/api/health')
    def health() -> dict[str, object]:
        return {'status': 'ok', 'ffmpeg': shutil.which(os.getenv('BJJ_FFMPEG_PATH', 'ffmpeg')) is not None,
                'ffprobe': shutil.which(os.getenv('BJJ_FFPROBE_PATH', 'ffprobe')) is not None}

    @application.get('/api/projects')
    def list_projects() -> list[dict[str, object]]:
        return store.list()

    @application.post('/api/projects/import', response_model=Project)
    async def import_video(file: Annotated[UploadFile, File()],
                           name: Annotated[str | None, Form()] = None) -> Project:
        content_type = (file.content_type or '').split(';')[0]
        if content_type and not (content_type.startswith('video/') or content_type in (
                'application/octet-stream', 'application/mp4', 'application/x-matroska')):
            await file.close()
            raise HTTPException(415, 'Choose a video file such as MP4, MOV, MKV, or WebM')
        original_name = safe_filename(file.filename or 'video.mp4')
        suffix = Path(original_name).suffix.lower()
        if len(suffix) > 12 or not suffix:
            suffix = '.bin'
        project_id = str(uuid4())
        folder = store.create_dir(project_id)
        source_asset, proxy_asset = f'source/{uuid4()}{suffix}', f'proxy/{uuid4()}.mp4'
        source_path, proxy_path = asset_path(folder, source_asset), asset_path(folder, proxy_asset)
        success = False
        try:
            count = 0
            with source_path.open('xb') as destination:
                while chunk := await file.read(1024 * 1024):
                    count += len(chunk)
                    if count > settings.max_upload_bytes:
                        raise HTTPException(413, 'Upload exceeds the configured size limit')
                    await run_in_threadpool(destination.write, chunk)
            if not count:
                raise HTTPException(422, 'The uploaded file is empty')
            if shutil.disk_usage(folder).free < max(count, 16 * 1024**2):
                raise HTTPException(507, 'Not enough disk space to create an editing proxy')
            source = await run_in_threadpool(probe_media, source_path, source_asset, original_name)
            await run_in_threadpool(create_proxy, source_path, proxy_path, source)
            proxy = await run_in_threadpool(probe_media, proxy_path, proxy_asset, original_name)
            now = utc_now()
            project = Project(projectId=project_id, projectName=(name or Path(original_name).stem)[:160],
                              createdAt=now, updatedAt=now, source=source, proxy=proxy,
                              exportSettings={'fps': min(120, source.avgFrameRate), 'crf': 18, 'preset': 'medium'})
            saved = await run_in_threadpool(store.save, project, existing=False)
            success = True
            log.info('Video imported', extra={'projectId': project_id})
            return saved
        finally:
            await file.close()
            if not success:
                shutil.rmtree(folder, ignore_errors=True)

    @application.get('/api/projects/{project_id}', response_model=Project)
    def get_project(project_id: str) -> Project:
        return store.load(project_id)

    @application.put('/api/projects/{project_id}', response_model=Project)
    def save_project(project_id: str, project: Project) -> Project:
        if project.projectId != project_id:
            raise HTTPException(400, 'Project identifier does not match the URL')
        return store.save(project)

    @application.delete('/api/projects/{project_id}', status_code=204)
    def delete_project(project_id: str) -> Response:
        with store.lock:
            if application.state.jobs.has_active(project_id):
                raise HTTPException(409, 'Cancel or finish this project’s active exports before deleting it')
            store.delete(project_id)
            application.state.jobs.forget(project_id)
        return Response(status_code=204)

    @application.get('/api/projects/{project_id}/video')
    def video(project_id: str) -> FileResponse:
        project = store.load(project_id)
        path = asset_path(store.project_dir(project_id), project.proxy.asset)
        if not path.is_file():
            raise FileNotFoundError()
        return FileResponse(path, media_type='video/mp4', headers={'Cache-Control': 'private, max-age=3600'})

    @application.post('/api/projects/{project_id}/exports')
    def start_export(project_id: str) -> Job:
        with store.lock:
            project = store.load(project_id)
            if not asset_path(store.project_dir(project_id), project.source.asset).is_file():
                raise HTTPException(404, 'The original video asset is missing')
            store.validate_voiceovers(project)
            return application.state.jobs.create(project)

    @application.get('/api/projects/{project_id}/exports')
    def list_exports(project_id: str) -> list[Job]:
        store.load(project_id)
        return application.state.jobs.list(project_id)

    @application.get('/api/exports/{job_id}')
    def export_status(job_id: str) -> Job:
        return application.state.jobs.get(job_id)

    @application.post('/api/exports/{job_id}/cancel')
    def cancel_export(job_id: str) -> Job:
        return application.state.jobs.cancel(job_id)

    @application.get('/api/exports/{job_id}/download')
    def download_export(job_id: str) -> FileResponse:
        job = application.state.jobs.get(job_id)
        if job.status != 'completed':
            raise HTTPException(409, 'The export is not ready for download')
        path = application.state.jobs.output_path(job)
        if not path.is_file():
            raise FileNotFoundError()
        return FileResponse(path, media_type='video/mp4', filename=job.filename)

    @application.post('/api/projects/{project_id}/voiceovers', response_model=Voiceover)
    async def upload_voiceover(project_id: str, file: Annotated[UploadFile, File()],
                               startSec: Annotated[float, Form(ge=0)]) -> Voiceover:
        project = store.load(project_id)
        if not math.isfinite(startSec) or startSec >= project.source.durationSec:
            await file.close()
            raise HTTPException(422, 'Position the playhead before the video ends to record commentary')
        mime_type = (file.content_type or '').split(';')[0]
        if mime_type and not (mime_type.startswith('audio/') or mime_type in (
                'application/octet-stream', 'video/webm', 'video/mp4', 'application/ogg')):
            await file.close()
            raise HTTPException(415, 'Choose a microphone recording in WebM, Ogg, WAV, or MP4 audio format')
        clip_id = str(uuid4())
        temporary = store.project_dir(project_id) / 'temp' / f'voiceover-{clip_id}'
        temporary.mkdir()
        try:
            uploaded, normalized = temporary / 'upload.bin', temporary / 'normalized.wav'
            received = 0
            limit = min(settings.max_upload_bytes, settings.max_voiceover_bytes)
            with uploaded.open('xb') as destination:
                while chunk := await file.read(1024 * 1024):
                    received += len(chunk)
                    if received > limit:
                        raise HTTPException(413, 'Recording exceeds the configured size limit')
                    await run_in_threadpool(destination.write, chunk)
            if not received:
                raise HTTPException(422, 'The recording is empty. Check the microphone and try again.')
            remaining = project.source.durationSec - startSec
            required_space = min(remaining * 96000, received * 100) + 16 * 1024**2
            if shutil.disk_usage(temporary).free < required_space:
                raise HTTPException(507, 'Not enough disk space to process the recording')
            audio = await run_in_threadpool(normalize_voiceover, uploaded, normalized, remaining)
            clip = Voiceover(id=clip_id, asset=f'voiceover/{clip_id}.wav', startSec=startSec,
                             durationSec=audio.duration_sec, endSec=startSec + audio.duration_sec,
                             recordedAt=utc_now(), codec=audio.codec,
                             sampleRate=audio.sample_rate, channels=audio.channels)
            result = await run_in_threadpool(store.register_voiceover, project_id, clip, normalized)
            log.info('Voiceover recorded', extra={'projectId': project_id})
            return result
        finally:
            await file.close()
            shutil.rmtree(temporary, ignore_errors=True)

    @application.get('/api/projects/{project_id}/voiceovers/{clip_id}/audio')
    def voiceover_audio(project_id: str, clip_id: str) -> FileResponse:
        clip = store.voiceover_metadata(project_id, clip_id)
        return FileResponse(asset_path(store.project_dir(project_id), clip.asset), media_type='audio/wav',
                            headers={'Cache-Control': 'private, max-age=3600'})

    @application.delete('/api/projects/{project_id}/voiceovers/{clip_id}', status_code=204)
    def delete_voiceover(project_id: str, clip_id: str) -> Response:
        with store.lock:
            if application.state.jobs.has_active(project_id):
                raise HTTPException(409, 'Cancel or finish active exports before permanently deleting a recording')
            store.delete_voiceover(project_id, clip_id)
        return Response(status_code=204)

    @application.get('/{path:path}')
    def frontend(path: str) -> FileResponse:
        if path.startswith('api/'):
            raise HTTPException(404, 'API endpoint not found')
        try:
            target = asset_path(settings.frontend_dir, path) if path else settings.frontend_dir / 'index.html'
        except StorageError:
            raise HTTPException(404, 'File not found') from None
        if not target.is_file():
            target = settings.frontend_dir / 'index.html'
        if not target.is_file():
            raise HTTPException(503, 'Frontend is not built. Run npm ci and npm run build in frontend.')
        return FileResponse(target)

    return application


app = create_app()
