"""Restart-observable package work. Only complete verified files are downloadable."""

from __future__ import annotations

import errno
import json
import os
import shutil
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field

from .errors import DomainError, conflict
from .package_archive import DEFAULT_LIMITS, PackageLimits
from .packages import backup, install, restore
from .storage import ProjectStore, StorageError, asset_path, atomic_json, require_uuid, utc_now

TERMINAL = {"completed", "failed", "cancelled"}


class PackageJob(BaseModel):
    model_config = ConfigDict(extra="forbid")
    jobId: str
    projectId: str
    projectRevision: int | None = None
    operation: Literal["backup", "restore"]
    status: Literal["queued", "running", "completed", "failed", "cancelled"] = "queued"
    stage: Literal[
        "copying", "inspecting", "packing", "extracting", "validating", "preparing_preview", "ready"
    ] = "inspecting"
    progress: float | None = Field(default=None, ge=0, le=1)
    completedUnits: int = Field(default=0, ge=0)
    totalUnits: int | None = Field(default=None, ge=0)
    includeProxy: bool = False
    cancelRequested: bool = False
    errorCode: str | None = None
    error: str | None = None
    createdAt: str


class PackageJobs:
    def __init__(self, store: ProjectStore, limits: PackageLimits = DEFAULT_LIMITS):
        self.store, self.limits = store, limits
        self.root = asset_path(store.root, "package-jobs")
        self.root.mkdir(exist_ok=True)
        self.lock = threading.RLock()
        self.jobs: dict[str, PackageJob] = {}
        self.events: dict[str, threading.Event] = {}
        self.readers: dict[str, int] = {}
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="bjj-package")
        self.closed = False
        for index, folder in enumerate(self.root.iterdir()):
            if index >= 1024:
                break
            try:
                require_uuid(folder.name)
                record = asset_path(self.root, f"{folder.name}/job.json")
                if record.stat().st_size > 64 * 1024:
                    continue
                job = PackageJob.model_validate_json(record.read_text())
                require_uuid(job.projectId)
                if job.jobId != folder.name or len(self.jobs) >= 64:
                    continue
                completed = asset_path(self.root, f"{folder.name}/completed.json")
                if job.status not in TERMINAL and completed.is_file() and completed.stat().st_size <= 65536:
                    final = PackageJob.model_validate_json(completed.read_text())
                    if (final.jobId == job.jobId and final.projectId == job.projectId
                            and final.operation == job.operation and final.status == "completed"):
                        job = final
                self.jobs[job.jobId] = job
                self.events[job.jobId] = threading.Event()
                if job.status not in TERMINAL:
                    job.status, job.errorCode, job.error = (
                        "failed",
                        "PACKAGE_INTERRUPTED",
                        "Package work was interrupted. Existing projects were preserved; start the operation again.",
                    )
                    marker = asset_path(self.store.project_dir(job.projectId), "restore-job.json")
                    if (
                        job.operation == "restore"
                        and marker.is_file()
                        and json.loads(marker.read_text()).get("jobId") == job.jobId
                    ):
                        project = store.load(job.projectId)
                        job.status, job.stage, job.progress = "completed", "ready", 1
                        job.projectRevision, job.error, job.errorCode = project.revision, None, None
                    self._persist(job)
                    for name in ("staging", "incoming.partial", "backup.partial"):
                        path = self.path(job.jobId, name)
                        if path.is_dir():
                            shutil.rmtree(path)
                        else:
                            path.unlink(missing_ok=True)
            except (OSError, ValueError, DomainError, StorageError):
                continue  # Unknown/corrupt records stay intact and cannot authorize file access.

    def path(self, job_id: str, name: str) -> Path:
        return asset_path(self.root, f"{require_uuid(job_id)}/{name}")

    def _persist(self, job: PackageJob) -> None:
        atomic_json(self.path(job.jobId, "job.json"), job.model_dump(mode="json"))

    def get(self, job_id: str) -> PackageJob:
        require_uuid(job_id)
        with self.lock:
            if job_id not in self.jobs:
                raise DomainError("PACKAGE_MISSING", "This package operation is unavailable.", 404)
            return self.jobs[job_id].model_copy(deep=True)

    def update(self, job_id: str, *, persist: bool = True, **changes) -> PackageJob:
        with self.lock:
            value = self.get(job_id).model_copy(update=changes)
            if persist and value.status == "completed":
                # A completed receipt survives a failed replacement of job.json.
                atomic_json(self.path(job_id, "completed.json"), value.model_dump(mode="json"))
                self.jobs[job_id] = value
                try:
                    self._persist(value)
                except OSError:
                    pass  # The identical completed receipt is already durable.
                return value
            self.jobs[job_id] = value
            if persist:
                self._persist(value)
            return value

    def create(
        self,
        operation: str,
        request_id: str,
        *,
        project_id: str | None = None,
        revision: int | None = None,
        include_proxy: bool = False,
    ) -> PackageJob:
        require_uuid(request_id)
        with self.lock, self.store.lock:
            if request_id in self.jobs:
                old = self.get(request_id)
                if old.operation != operation or (
                    operation == "backup"
                    and (
                        old.projectId != project_id
                        or old.projectRevision != revision
                        or old.includeProxy != include_proxy
                    )
                ):
                    raise DomainError(
                        "PROJECT_CONFLICT",
                        "This request identifier already belongs to another operation.",
                        409,
                    )
                return old
            if operation not in ("backup", "restore") or type(include_proxy) is not bool:
                raise DomainError("PACKAGE_INVALID", "Choose backup or restore.", 400)
            if (
                self.closed
                or sum(job.status not in TERMINAL for job in self.jobs.values()) >= 2
                or len(self.jobs) >= 64
            ):
                raise DomainError(
                    "PACKAGE_LIMIT",
                    "Finish or remove an older package operation before starting another.",
                    409,
                )
            project = None
            if operation == "backup":
                project = self.store.load(project_id)
                if project.revision != revision:
                    raise conflict(project.revision)
                self.store.acquire_lease(project.projectId)
            folder = self.path(request_id, "job.json").parent
            created = False
            try:
                folder.mkdir(exist_ok=False)
                created = True
                job = PackageJob(
                    jobId=request_id,
                    projectId=project.projectId if project else str(uuid4()),
                    projectRevision=revision if project else None,
                    operation=operation,
                    includeProxy=include_proxy,
                    stage="inspecting" if project else "copying",
                    createdAt=utc_now(),
                )
                if project:
                    atomic_json(folder / "input.json", project.model_dump(mode="json"))
                self.jobs[job.jobId], self.events[job.jobId] = job, threading.Event()
                self._persist(job)
                if project:
                    self.executor.submit(self._backup, job.jobId, project)
                return job.model_copy(deep=True)
            except BaseException:
                if project:
                    self.store.release_lease(project.projectId)
                self.jobs.pop(request_id, None)
                self.events.pop(request_id, None)
                if created:
                    shutil.rmtree(folder)
                raise

    def progress(self, job_id: str, stage: str, done: int, total: int | None) -> None:
        self.update(
            job_id,
            persist=False,
            status="running",
            stage=stage,
            completedUnits=done,
            totalUnits=total,
            progress=min(1, done / total) if total else None,
        )

    def fail(self, job_id: str, error: Exception) -> None:
        cancelled = self.events[job_id].is_set() or getattr(error, "code", None) == "JOB_CANCELLED"
        low = isinstance(error, OSError) and error.errno == errno.ENOSPC
        code = (
            "JOB_CANCELLED"
            if cancelled
            else ("STORAGE_LOW" if low else getattr(error, "code", "PACKAGE_FAILED"))
        )
        message = (
            "Package work was cancelled. Existing projects were preserved."
            if cancelled
            else "Not enough free storage. Existing projects were preserved."
            if low
            else str(error)
            if isinstance(error, DomainError)
            else "Package work failed. Existing projects were preserved; retry with a complete backup."
        )
        self.update(job_id, status="cancelled" if cancelled else "failed", errorCode=code, error=message)

    def _backup(self, job_id, project) -> None:
        temporary = None
        try:
            temporary = self.path(job_id, "backup.partial")
            backup(
                self.store,
                project,
                temporary,
                self.get(job_id).includeProxy,
                self.events[job_id],
                lambda *event: self.progress(job_id, *event),
                self.limits,
            )
            with self.lock:
                if self.events[job_id].is_set():
                    raise DomainError("JOB_CANCELLED", "Package work was cancelled.", 409)
                os.rename(temporary, self.path(job_id, "backup.bjjproj"))
                self.update(job_id, status="completed", stage="ready", progress=1)
        except Exception as error:
            if self.get(job_id).status != "completed":
                self.fail(job_id, error)
        finally:
            try:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
            finally:
                self.store.release_lease(project.projectId)

    def begin_upload(self, job_id: str) -> Path:
        with self.lock:
            job = self.get(job_id)
            if job.operation != "restore" or job.status != "queued":
                raise DomainError(
                    "PROJECT_CONFLICT", "This package upload is already active or finished.", 409
                )
            self.update(job_id, status="running", stage="copying")
            return self.path(job_id, "incoming.partial")

    def finish_upload(self, job_id: str) -> PackageJob:
        with self.lock:
            if self.events[job_id].is_set():
                raise DomainError("JOB_CANCELLED", "Package work was cancelled.", 409)
            os.rename(self.path(job_id, "incoming.partial"), self.path(job_id, "incoming.bjjproj"))
            self.update(job_id, stage="inspecting", progress=None)
            self.executor.submit(self._restore, job_id)
            return self.get(job_id)

    def _restore(self, job_id: str) -> None:
        job = self.get(job_id)

        def publish(folder, project):
            with self.lock:
                atomic_json(folder / "restore-job.json", {"version": 1, "jobId": job_id})
                result = install(self.store, folder, project, self.events[job_id])
                self.update(
                    job_id, projectRevision=result.revision, status="completed", stage="ready", progress=1
                )
                return result

        try:
            restore(
                self.store,
                self.path(job_id, "incoming.bjjproj"),
                self.path(job_id, "staging"),
                job.projectId,
                self.events[job_id],
                lambda *event: self.progress(job_id, *event),
                self.limits,
                publish=publish,
            )
        except Exception as error:
            if self.get(job_id).status != "completed":
                self.fail(job_id, error)

    def cancel(self, job_id: str) -> PackageJob:
        with self.lock:
            job = self.get(job_id)
            if job.status in TERMINAL:
                return job
            self.events[job_id].set()
            self.update(job_id, cancelRequested=True)
            if job.operation == "restore" and job.status == "queued":
                self.fail(job_id, DomainError("JOB_CANCELLED", "Cancelled", 409))
            return self.get(job_id)

    def acquire_output(self, job_id: str) -> Path:
        with self.lock:
            job = self.get(job_id)
            if job.operation != "backup" or job.status != "completed":
                raise DomainError("PACKAGE_UNAVAILABLE", "The backup is not ready to download.", 409)
            path = self.path(job_id, "backup.bjjproj")
            if not path.is_file():
                raise DomainError(
                    "PACKAGE_MISSING", "This backup file was removed. Create another backup.", 404
                )
            self.readers[job_id] = self.readers.get(job_id, 0) + 1
            return path

    def release_output(self, job_id: str) -> None:
        with self.lock:
            self.readers[job_id] = max(0, self.readers.get(job_id, 0) - 1)

    def remove(self, job_id: str) -> None:
        with self.lock:
            if self.get(job_id).status not in TERMINAL or self.readers.get(job_id, 0):
                raise DomainError("PACKAGE_BUSY", "This package is in use. Finish or cancel it first.", 409)
            shutil.rmtree(self.path(job_id, "job.json").parent)
            self.jobs.pop(job_id)
            self.events.pop(job_id)

    def close(self) -> None:
        with self.lock:
            self.closed = True
            for identifier, job in self.jobs.items():
                if job.status not in TERMINAL:
                    self.events[identifier].set()
        self.executor.shutdown(wait=True, cancel_futures=False)
