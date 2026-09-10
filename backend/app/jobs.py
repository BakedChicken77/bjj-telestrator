"""Tracked, persistent export jobs; immutable snapshots isolate concurrent edits."""
from __future__ import annotations

import logging
import shutil
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

from .models import Job, Project
from .storage import ProjectStore, StorageError, atomic_json, require_uuid, safe_filename, utc_now

log = logging.getLogger(__name__)
TERMINAL = {'completed', 'failed', 'cancelled'}


class JobManager:
    def __init__(self, store: ProjectStore, workers: int = 1,
                 renderer: Callable[..., None] | None = None):
        self.store = store
        self.executor = ThreadPoolExecutor(max_workers=max(1, workers), thread_name_prefix='export')
        self.lock = threading.RLock()
        self.jobs: dict[str, Job] = {}
        self.cancel_events: dict[str, threading.Event] = {}
        self.renderer = renderer
        self.closed = False
        self._recover()

    def _recover(self) -> None:
        for metadata in self.store.root.glob('*/exports/*.json'):
            try:
                job = Job.model_validate_json(metadata.read_text('utf-8'))
                require_uuid(job.jobId)
                require_uuid(job.projectId)
                if metadata.parent.parent.name != job.projectId or metadata.stem != job.jobId:
                    continue
                self.jobs[job.jobId] = job
                if job.status not in TERMINAL:
                    job.status = 'failed'
                    job.error = 'Export interrupted by a backend restart. Start a new export.'
                    self._persist(job)
                    (metadata.parent / f'{job.jobId}.mp4').unlink(missing_ok=True)
                shutil.rmtree(metadata.parent.parent / 'temp' / job.jobId, ignore_errors=True)
            except Exception:
                log.exception('Unable to recover export job')

    def _persist(self, job: Job) -> None:
        atomic_json(self.store.project_dir(job.projectId) / 'exports' / f'{job.jobId}.json',
                    job.model_dump(mode='json'))

    def create(self, project: Project) -> Job:
        with self.lock:
            if self.closed:
                raise StorageError('The backend is shutting down. Try again after restart.')
            if sum(j.status not in TERMINAL for j in self.jobs.values()) >= 8:
                raise StorageError('The export queue is full. Wait for a job to finish.')
            job = Job(jobId=str(uuid4()), projectId=project.projectId, createdAt=utc_now())
            job.filename = f'{safe_filename(project.projectName, "review")}-annotated-{job.createdAt[:19].replace(":", "-")}.mp4'
            self.jobs[job.jobId] = job
            self.cancel_events[job.jobId] = threading.Event()
            self._persist(job)
            self.executor.submit(self._run, job.jobId, project.model_copy(deep=True))
            return job.model_copy(deep=True)

    def get(self, job_id: str) -> Job:
        require_uuid(job_id)
        with self.lock:
            if job_id not in self.jobs:
                raise FileNotFoundError()
            return self.jobs[job_id].model_copy(deep=True)

    def list(self, project_id: str) -> list[Job]:
        return sorted((self.get(j.jobId) for j in list(self.jobs.values()) if j.projectId == project_id),
                      key=lambda j: j.createdAt, reverse=True)

    def has_active(self, project_id: str) -> bool:
        with self.lock:
            return any(j.projectId == project_id and j.status not in TERMINAL for j in self.jobs.values())

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
        return self.store.project_dir(job.projectId) / 'exports' / f'{require_uuid(job.jobId)}.mp4'

    def _run(self, job_id: str, project: Project) -> None:
        from .renderer import ExportCancelled, render_export

        with self.lock:
            job = self.jobs[job_id]
            event = self.cancel_events[job_id]
            if event.is_set():
                job.status = 'cancelled'
                self._persist(job)
                self.cancel_events.pop(job_id, None)
                return
            job.status = 'running'
            self._persist(job)
        folder = self.store.project_dir(project.projectId)
        temp = folder / 'temp' / job_id
        output = self.output_path(job)
        try:
            temp.mkdir(parents=True, exist_ok=True)

            def progress(rendered_sec: float) -> None:
                with self.lock:
                    job.renderedSec = min(project.source.durationSec, max(0, rendered_sec))
                    job.progress = min(99.9, job.renderedSec / project.source.durationSec * 100)

            (self.renderer or render_export)(project, folder, output, temp, progress, event)
            with self.lock:
                if event.is_set():
                    raise ExportCancelled()
                if not output.is_file() or output.stat().st_size == 0:
                    raise RuntimeError('Renderer produced no output')
                job.status, job.progress, job.renderedSec = 'completed', 100, project.source.durationSec
                self._persist(job)
        except ExportCancelled:
            with self.lock:
                job.status, job.error = 'cancelled', None
                self._persist(job)
            output.unlink(missing_ok=True)
        except Exception:
            log.exception('Export failed', extra={'jobId': job_id, 'projectId': project.projectId})
            with self.lock:
                job.status = 'failed'
                job.error = 'Export failed. Verify the source exists, free disk space, and FFmpeg installation; see backend logs.'
                self._persist(job)
            output.unlink(missing_ok=True)
        finally:
            shutil.rmtree(temp, ignore_errors=True)
            with self.lock:
                self.cancel_events.pop(job_id, None)

    def close(self) -> None:
        with self.lock:
            self.closed = True
            for event in self.cancel_events.values():
                event.set()
        self.executor.shutdown(wait=True, cancel_futures=False)
