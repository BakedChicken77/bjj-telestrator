"""Durable immutable export attempts and leased, atomically published MP4s."""
from __future__ import annotations

import errno
import logging
import os
import shutil
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

from .assets import export_estimate, require_space
from .errors import DomainError
from .models import Job, Project
from .render_plan import build_plan, read_plan, verify_assets
from .storage import ProjectStore, StorageError, asset_path, atomic_json, require_uuid, safe_filename, utc_now

log = logging.getLogger(__name__)
TERMINAL = {'completed', 'failed', 'cancelled'}


def validate_output(path: Path, project: Project) -> None:
    from .media import probe_media
    from .renderer import audible_voiceovers, output_dimensions
    media = probe_media(path, 'exports/output.mp4', 'output.mp4')
    audio = project.source.hasAudio or bool(audible_voiceovers(project))
    if (media.codec != 'h264' or (media.displayWidth, media.displayHeight) != output_dimensions(project.source)
            or abs(media.durationSec - project.source.durationSec) > max(.1, 1 / project.exportSettings.fps)
            or media.hasAudio != audio or (audio and media.audioCodec != 'aac')):
        raise DomainError('EXPORT_VALIDATION_FAILED', 'The MP4 failed its codec, dimensions, audio or duration check. Retry the export.')


class JobManager:
    def __init__(self, store: ProjectStore, workers: int = 1,
                 renderer: Callable[..., None] | None = None,
                 validator: Callable[[Path, Project], None] = validate_output):
        self.store = store
        self.executor = ThreadPoolExecutor(max_workers=max(1, workers), thread_name_prefix='export')
        self.lock = threading.RLock()
        self.jobs: dict[str, Job] = {}
        self.cancel_events: dict[str, threading.Event] = {}
        self.reservations: dict[str, int] = {}
        self.downloads: dict[str, int] = {}
        self.renderer, self.validator = renderer, validator
        self.closed = False
        self._recover()

    def input_path(self, job: Job) -> Path:
        return asset_path(self.store.project_dir(job.projectId), f'exports/inputs/{require_uuid(job.jobId)}.json')

    def _recover(self) -> None:
        for folder in self.store.root.iterdir():
            try:
                require_uuid(folder.name)
                self.recover_project(folder.name)
            except StorageError:
                continue

    def recover_project(self, project_id: str) -> None:
        for metadata in asset_path(self.store.project_dir(project_id), 'exports').glob('*.json'):
            try:
                if metadata.stat().st_size > 1024**2 or metadata.is_symlink():
                    continue
                job = Job.model_validate_json(metadata.read_text('utf-8'))
                require_uuid(job.jobId)
                require_uuid(job.projectId)
                if metadata.parent.parent.name != job.projectId or metadata.stem != job.jobId:
                    continue
                if job.jobId in self.jobs:
                    continue  # Never rewrite an active or other project's job on restore.
                job.retryAvailable = self.input_path(job).is_file()
                if job.status not in TERMINAL:
                    job.status = 'failed'
                    job.errorCode = 'EXPORT_INTERRUPTED'
                    job.error = ('Export interrupted by a backend restart. Retry this revision from the beginning.'
                                 if job.retryAvailable else 'Export interrupted by a backend restart. Render the current review.')
                if job.status != 'completed':
                    self.output_path(job).unlink(missing_ok=True)
                job.outputAvailable = job.status == 'completed' and self.output_path(job).is_file()
                self.jobs[job.jobId] = job
                self._persist(job)
                shutil.rmtree(metadata.parent.parent / 'temp' / job.jobId, ignore_errors=True)
            except Exception:
                log.exception('Unable to recover export job')

    def _persist(self, job: Job) -> None:
        atomic_json(asset_path(self.store.project_dir(job.projectId), f'exports/{require_uuid(job.jobId)}.json'), job.model_dump(mode='json'))

    def create(self, project: Project, *, plan: dict | None = None, retry_of: str | None = None) -> Job:
        self.store.acquire_lease(project.projectId)
        job: Job | None = None
        input_file: Path | None = None
        try:
            # Hashing uses a separate inventory lock, so ordinary autosaves continue.
            snapshot = plan if plan is not None else build_plan(self.store, project)
            with self.lock:
                if self.closed:
                    raise StorageError('The backend is shutting down. Try again after restart.')
                if len(self.cancel_events) >= 8:
                    raise StorageError('The export queue is full. Wait for a job to finish.')
                estimate = export_estimate(project)
                require_space(self.store.root, estimate, sum(self.reservations.values()))
                job = Job(jobId=str(uuid4()), projectId=project.projectId, createdAt=utc_now(),
                          projectRevision=project.revision, retryOf=retry_of, retryAvailable=True)
                job.filename = f'{safe_filename(project.projectName, "review")}-annotated-{job.createdAt[:19].replace(":", "-")}.mp4'
                input_file = self.input_path(job)
                atomic_json(input_file, snapshot)
                self._persist(job)  # A queued job is published only after its input is durable.
                self.jobs[job.jobId] = job
                self.cancel_events[job.jobId] = threading.Event()
                self.reservations[job.jobId] = estimate['requiredBytes']
                self.executor.submit(self._run, job.jobId)
                return job.model_copy(deep=True)
        except BaseException:
            try:
                if job:
                    with self.lock:
                        self.jobs.pop(job.jobId, None)
                        self.cancel_events.pop(job.jobId, None)
                        self.reservations.pop(job.jobId, None)
                    if input_file:
                        input_file.unlink(missing_ok=True)
                        (input_file.parent.parent / f'{job.jobId}.json').unlink(missing_ok=True)
            finally:
                self.store.release_lease(project.projectId)
            raise

    def retry(self, job_id: str) -> Job:
        previous = self.get(job_id)
        if previous.status not in TERMINAL:
            raise DomainError('JOB_ACTIVE', 'Finish or cancel this attempt before retrying.', 409)
        plan = read_plan(self.input_path(previous), previous.projectId, previous.projectRevision)
        return self.create(Project.model_validate(plan['project']), plan=plan, retry_of=previous.jobId)

    def get(self, job_id: str) -> Job:
        require_uuid(job_id)
        with self.lock:
            if job_id not in self.jobs:
                raise FileNotFoundError()
            return self.jobs[job_id].model_copy(deep=True)

    def list(self, project_id: str) -> list[Job]:
        with self.lock:
            return sorted((j.model_copy(deep=True) for j in self.jobs.values() if j.projectId == project_id),
                          key=lambda j: j.createdAt, reverse=True)

    def has_active(self, project_id: str) -> bool:
        with self.lock:
            return any(j.projectId == project_id and j.jobId in self.cancel_events for j in self.jobs.values())

    def forget(self, project_id: str) -> None:
        with self.lock:
            self.jobs = {k: v for k, v in self.jobs.items() if v.projectId != project_id}

    def cancel(self, job_id: str) -> Job:
        with self.lock:
            self.get(job_id)
            job = self.jobs[job_id]
            if job.status not in TERMINAL:
                self.cancel_events[job_id].set()
                if job.status == 'queued':
                    job.status = 'cancelled'
                    self._persist(job)
            return job.model_copy(deep=True)

    def output_path(self, job: Job) -> Path:
        return asset_path(self.store.project_dir(job.projectId), f'exports/{require_uuid(job.jobId)}.mp4')

    def acquire_output(self, job_id: str) -> tuple[Job, Path]:
        job = self.get(job_id)
        self.store.acquire_lease(job.projectId)
        try:
            with self.lock:
                job = self.get(job_id)
                if job.status != 'completed' or not job.outputAvailable or not self.output_path(job).is_file():
                    raise DomainError('EXPORT_UNAVAILABLE', 'This MP4 is unavailable. Retry its saved revision to render it again.', 409)
                self.downloads[job_id] = self.downloads.get(job_id, 0) + 1
                return job, self.output_path(job)
        except BaseException:
            self.store.release_lease(job.projectId)
            raise

    def release_output(self, job: Job) -> None:
        with self.lock:
            self.downloads[job.jobId] = max(0, self.downloads.get(job.jobId, 0) - 1)
        self.store.release_lease(job.projectId)

    def remove_output(self, job_id: str) -> Job:
        with self.lock:
            job = self.get(job_id)
            if job.status != 'completed' or job_id in self.cancel_events or self.downloads.get(job_id, 0):
                raise DomainError('ASSET_BUSY', 'Finish rendering or sharing this MP4 before removing it.', 409)
            # Never touch inputs or media. Publish unavailability before unlinking.
            job.outputAvailable = False
            self._persist(job)
            self.jobs[job_id] = job
            self.output_path(job).unlink(missing_ok=True)
            return job.model_copy(deep=True)

    def _run(self, job_id: str) -> None:
        from .renderer import ExportCancelled, render_export
        job = self.get(job_id)
        event = self.cancel_events[job_id]
        folder = self.store.project_dir(job.projectId)
        temp: Path | None = None
        output: Path | None = None
        try:
            temp = asset_path(folder, f'temp/{job_id}')
            output = self.output_path(job)
            if event.is_set():
                raise ExportCancelled()
            with self.lock:
                job.status = 'running'
                self.jobs[job_id] = job
                self._persist(job)
            plan = read_plan(self.input_path(job), job.projectId, job.projectRevision)
            project = Project.model_validate(plan['project'])
            require_space(folder, export_estimate(project))
            verify_assets(folder, plan, event)
            temp.mkdir(parents=True, exist_ok=True)
            staging = temp / 'output.mp4'

            def progress(rendered_sec: float) -> None:
                with self.lock:
                    job.renderedSec = min(project.source.durationSec, max(0, rendered_sec))
                    job.progress = min(99.9, job.renderedSec / project.source.durationSec * 100)

            (self.renderer or render_export)(project, folder, staging, temp, progress, event)
            self.validator(staging, project)
            verify_assets(folder, plan, event)
            with self.lock:
                if event.is_set():
                    raise ExportCancelled()
                if not staging.is_file() or staging.stat().st_size == 0:
                    raise RuntimeError('Renderer produced no output')
                os.replace(staging, output)
                job.status, job.progress, job.renderedSec = 'completed', 100, project.source.durationSec
                job.outputAvailable = True
                self._persist(job)
        except Exception as exc:
            with self.lock:
                job.status = 'cancelled' if isinstance(exc, ExportCancelled) else 'failed'
                job.outputAvailable = False
                if isinstance(exc, ExportCancelled):
                    job.error = job.errorCode = None
                elif isinstance(exc, DomainError):
                    job.error, job.errorCode = str(exc), exc.code
                elif isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
                    job.error, job.errorCode = 'Storage filled during export. Free space and retry this revision.', 'STORAGE_LOW'
                else:
                    log.exception('Export failed')
                    job.error, job.errorCode = 'Export failed. Check available storage and source media, then retry this revision.', 'EXPORT_FAILED'
                self.jobs[job_id] = job
                try:
                    self._persist(job)
                except OSError:
                    log.exception('Could not persist terminal status; restart recovery will mark it interrupted')
            if output:
                output.unlink(missing_ok=True)
        finally:
            if temp:
                shutil.rmtree(temp, ignore_errors=True)
            with self.lock:
                self.cancel_events.pop(job_id, None)
                self.reservations.pop(job_id, None)
            self.store.release_lease(job.projectId)

    def close(self) -> None:
        with self.lock:
            self.closed = True
            for event in self.cancel_events.values():
                event.set()
        self.executor.shutdown(wait=True, cancel_futures=False)
