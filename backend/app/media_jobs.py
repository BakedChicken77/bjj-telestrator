"""Tracked local import/repair operations; only validated previews become current."""
from __future__ import annotations

import errno
import json
import os
import shutil
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from typing import Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .assets import digest_file, manifest_assets, proxy_estimate, require_space
from .color import HDR_CAPABILITY, is_hdr, require_supported_color
from .errors import DomainError, conflict
from .media import check_cancelled, create_proxy, probe_media, proxy_dimensions, require_sdr
from .models import Media, Project
from .storage import ProjectStore, StorageError, asset_path, atomic_json, require_uuid, utc_now

TERMINAL = {'completed', 'failed', 'cancelled'}


class MediaJob(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra='forbid')
    jobId: str
    projectId: str
    operation: Literal['import', 'repair']
    status: Literal['queued', 'running', 'completed', 'failed', 'cancelled'] = 'queued'
    stage: Literal['copying', 'inspecting', 'preparing_preview', 'validating', 'ready'] = 'copying'
    progress: float | None = Field(default=None, ge=0, le=1)
    copiedBytes: int = Field(default=0, ge=0)
    totalBytes: int | None = Field(default=None, ge=0)
    cancelRequested: bool = False
    errorCode: str | None = None
    error: str | None = None
    projectRevision: int | None = Field(default=None, ge=1)
    createdAt: str

    @field_validator('jobId', 'projectId')
    @classmethod
    def identifier(cls, value: str) -> str:
        try:
            return require_uuid(value)
        except StorageError as exc:
            raise ValueError('Invalid media job identifier') from exc


def validate_proxy(source: Media, preview: Media) -> Media:
    require_sdr(preview)
    if is_hdr(source.model_dump(mode='json')) and (preview.transferFunction, preview.colorPrimaries, preview.colorMatrix, preview.colorRange) != ('bt709', 'bt709', 'bt709', 'tv'):
        raise DomainError('MEDIA_VALIDATION_FAILED', 'The HDR preview did not validate as Rec.709 SDR.', 422)
    if (preview.codec != 'h264' or (preview.displayWidth, preview.displayHeight) != proxy_dimensions(source)
            or preview.rotation != 0 or preview.avgFrameRate > 30.01
            or abs(preview.durationSec - source.durationSec) > max(.1, 1 / min(30, source.avgFrameRate))
            or preview.hasAudio != source.hasAudio or (source.hasAudio and preview.audioCodec != 'aac')):
        raise DomainError('MEDIA_VALIDATION_FAILED', 'The preview failed its orientation, timing, codec or audio check. The previous project was preserved.', 422)
    # Annotation/transport time is source time, independent of proxy frame rounding.
    return preview.model_copy(update={'durationSec': source.durationSec})


class MediaJobs:
    def __init__(self, store: ProjectStore):
        self.store = store
        self.lock = threading.RLock()
        self.jobs: dict[str, MediaJob] = {}
        self.events: dict[str, threading.Event] = {}
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='media')
        self.closed = False
        self.root = asset_path(store.root, 'media-jobs')
        self.root.mkdir(exist_ok=True)
        self._recover()

    def _path(self, job_id: str) -> Path:
        return asset_path(self.root, f'{require_uuid(job_id)}.json')

    def _persist(self, job: MediaJob) -> None:
        atomic_json(self._path(job.jobId), {'version': 1, 'job': job.model_dump()})

    def _recover(self) -> None:
        for path in sorted(self.root.glob('*.json'))[:256]:
            try:
                if path.is_symlink() or path.stat().st_size > 65536:
                    continue
                record = json.loads(path.read_bytes())
                if type(record['version']) is not int or record['version'] != 1:
                    continue
                job = MediaJob.model_validate(record['job'])
                if job.jobId != path.stem:
                    continue
                if job.status not in TERMINAL:
                    job.status, job.errorCode = 'failed', 'MEDIA_INTERRUPTED'
                    job.error = 'Video preparation stopped when the app closed. Import again or repair the preview; saved projects were preserved.'
                    folder = self.store.project_dir(job.projectId)
                    if job.operation == 'import' and (folder / 'project.json').is_file():
                        job.status, job.stage, job.progress = 'completed', 'ready', 1
                        job.projectRevision = self.store.load(job.projectId).revision
                        job.error = job.errorCode = None
                    elif job.operation == 'import':
                        shutil.rmtree(folder, ignore_errors=True)
                    asset_path(folder, f'temp/media-{job.jobId}.mp4').unlink(missing_ok=True)
                    asset_path(folder, f'temp/media-{job.jobId}.ffmpeg.log').unlink(missing_ok=True)
                    self._persist(job)
                self.jobs[job.jobId] = job
                self.events[job.jobId] = threading.Event()
            except (ValueError, KeyError, OSError, StorageError):
                continue  # Preserve unreadable records without exposing paths or hiding live projects.

    def create(self, project: Project | None = None) -> MediaJob:
        with self.lock:
            if self.closed or sum(job.status not in TERMINAL for job in self.jobs.values()) >= 2:
                raise DomainError('JOB_ACTIVE', 'Finish or cancel the current video preparation first.', 409)
            if len(self.jobs) >= 256:
                oldest = min((j for j in self.jobs.values() if j.status in TERMINAL), key=lambda j: (j.createdAt, j.jobId))
                self._path(oldest.jobId).unlink(missing_ok=True)
                del self.jobs[oldest.jobId], self.events[oldest.jobId]
            job = MediaJob(jobId=str(uuid4()), projectId=project.projectId if project else str(uuid4()),
                           operation='repair' if project else 'import', createdAt=utc_now(),
                           stage='inspecting' if project else 'copying')
            self._persist(job)
            self.jobs[job.jobId], self.events[job.jobId] = job, threading.Event()
            return job.model_copy(deep=True)

    def get(self, job_id: str) -> MediaJob:
        with self.lock:
            require_uuid(job_id)
            if job_id not in self.jobs:
                raise DomainError('JOB_MISSING', 'This video preparation is no longer available. Start it again.', 404)
            return self.jobs[job_id].model_copy(deep=True)

    def begin_import(self, job_id: str) -> Path:
        with self.lock:
            job = self.get(job_id)
            check_cancelled(self.events[job_id])
            if job.operation != 'import' or job.status != 'queued':
                raise DomainError('JOB_ACTIVE', 'This import was already started. Check its status before retrying.', 409)
            self.update(job_id, status='running')
            return self.store.create_dir(job.projectId)

    def update(self, job_id: str, *, persist: bool = True, **fields: object) -> None:
        with self.lock:
            job = self.jobs[job_id]
            if job.status in TERMINAL:
                return
            for key, value in fields.items():
                setattr(job, key, value)
            if persist:
                self._persist(job)

    def copied(self, job_id: str, count: int, total: int | None) -> None:
        check_cancelled(self.events[job_id])
        self.update(job_id, persist=False, copiedBytes=count, totalBytes=total,
                    progress=min(1, count / total) if total else None)

    def cancel(self, job_id: str) -> MediaJob:
        with self.lock:
            job = self.get(job_id)
            if job.status not in TERMINAL:
                self.events[job_id].set()
                self.update(job_id, cancelRequested=True, **({'status': 'cancelled', 'errorCode': 'JOB_CANCELLED'} if job.status == 'queued' else {}))
            return self.get(job_id)

    def fail(self, job_id: str, error: BaseException) -> None:
        cancelled = self.events[job_id].is_set()
        code = 'JOB_CANCELLED' if cancelled else (error.code if isinstance(error, DomainError) else
                'STORAGE_LOW' if isinstance(error, OSError) and error.errno == errno.ENOSPC else 'MEDIA_FAILED')
        message = ('Video preparation was cancelled.' if cancelled else str(error) if isinstance(error, DomainError) else
                   'Video preparation failed. Check free storage and choose a complete supported source. Existing projects were preserved.')
        self.update(job_id, status='cancelled' if cancelled else 'failed', errorCode=code, error=message)

    def import_copied(self, job_id: str, source_asset: str, original_name: str, name: str | None) -> Future[Project]:
        return self.executor.submit(self._prepare, job_id, source_asset, original_name, name, None)

    def repair(self, project_id: str, revision: int) -> MediaJob:
        with self.store.lock:
            project = self.store.load(project_id)
            if project.revision != revision:
                raise conflict(project.revision)
            self.store.acquire_lease(project_id)
        try:
            job = self.create(project)
            self.executor.submit(self._prepare, job.jobId, project.source.asset, project.source.originalFilename, None, project)
            return job
        except BaseException:
            self.store.release_lease(project_id)
            raise

    def _prepare(self, job_id: str, source_asset: str, original_name: str, name: str | None, snapshot: Project | None) -> Project:
        try:
            return self._prepare_media(job_id, source_asset, original_name, name, snapshot)
        except BaseException as exc:
            self.fail(job_id, exc)
            if self.events[job_id].is_set():
                raise DomainError('JOB_CANCELLED', 'Video preparation was cancelled.', 409) from exc
            raise
        finally:
            # Path validation and cleanup can also fail; neither may leak a lease.
            if snapshot:
                self.store.release_lease(snapshot.projectId)

    def _prepare_media(self, job_id: str, source_asset: str, original_name: str, name: str | None, snapshot: Project | None) -> Project:
        job, cancel = self.get(job_id), self.events[job_id]
        folder = self.store.project_dir(job.projectId)
        temporary = asset_path(folder, f'temp/media-{job_id}.mp4')
        proxy_asset = f'proxy/{uuid4()}.mp4'
        candidate = asset_path(folder, proxy_asset)
        try:
            check_cancelled(cancel)
            self.update(job_id, status='running', stage='inspecting', progress=None)
            source_path = asset_path(folder, source_asset)
            if snapshot:
                source_hash = manifest_assets(self.store, snapshot.model_copy(update={'voiceovers': []}), cancel=cancel)[0]['sha256']
            else:
                source_hash = digest_file(source_path, cancel)
            source = probe_media(source_path, source_asset, original_name, cancel)
            require_supported_color(source.model_dump(mode='json'))
            if snapshot and (abs(source.durationSec - snapshot.source.durationSec) > .001
                             or abs(source.videoStartSec - snapshot.source.videoStartSec) > .001
                             or (source.displayWidth, source.displayHeight) != (snapshot.source.displayWidth, snapshot.source.displayHeight)):
                raise DomainError('ASSET_CHANGED', 'The original video no longer matches this review. Restore its original file.', 409)
            require_space(folder, proxy_estimate(source.durationSec))
            self.update(job_id, stage='preparing_preview', progress=0)
            create_proxy(source_path, temporary, source, cancel,
                         lambda seconds: self.update(job_id, persist=False, progress=min(1, seconds / source.durationSec)))
            self.update(job_id, stage='validating', progress=None)
            preview = validate_proxy(source, probe_media(temporary, proxy_asset, original_name, cancel))
            if digest_file(source_path, cancel) != source_hash:
                raise DomainError('ASSET_CHANGED', 'The original changed during preparation. Restore its original file.', 409)
            # Cancel and commit are serialized: a completed import is never reported as cancelled.
            with self.lock, self.store.lock:
                check_cancelled(cancel)
                if snapshot:
                    current = self.store.load(snapshot.projectId)
                    if current.revision != snapshot.revision:
                        raise conflict(current.revision)
                    project = current.model_copy(update={'proxy': preview})
                else:
                    now = utc_now()
                    title = (name or Path(original_name).stem).strip()[:160] or 'Rolling review'
                    project = Project(projectId=job.projectId, projectName=title, createdAt=now, updatedAt=now,
                                      source=source, proxy=preview,
                                      requiredCapabilities=['project.revisions.v1'] + ([HDR_CAPABILITY] if is_hdr(source.model_dump(mode='json')) else []),
                                      exportSettings={'fps': min(120, source.avgFrameRate), 'crf': 18, 'preset': 'medium'})
                os.rename(temporary, candidate)
                saved = self.store.save(project, existing=snapshot is not None, replacing_proxy=snapshot is not None)
                self.update(job_id, status='completed', stage='ready', progress=1, projectRevision=saved.revision)
                return saved
        finally:
            temporary.unlink(missing_ok=True)
            committed = folder / 'project.json'
            # A successful atomic save still owns its proxy if later job-status persistence fails.
            if committed.is_file():
                try:
                    if self.store.load(job.projectId).proxy.asset != proxy_asset:
                        candidate.unlink(missing_ok=True)
                except (ValueError, OSError):
                    pass
            elif not snapshot:
                shutil.rmtree(folder, ignore_errors=True)

    def close(self) -> None:
        with self.lock:
            self.closed = True
            for job_id in self.jobs:
                if self.jobs[job_id].status not in TERMINAL:
                    self.events[job_id].set()
        self.executor.shutdown(wait=True, cancel_futures=False)
