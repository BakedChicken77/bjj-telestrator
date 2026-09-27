"""Portable editable projects. Immutable inputs, staged validation, atomic copies."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import threading
import wave
import zipfile
from collections.abc import Callable
from pathlib import Path
from uuid import uuid4

from pydantic import ValidationError

from .assets import (
    immutable_file,
    manifest_assets,
    proxy_estimate,
    require_space,
    required_assets,
    space_estimate,
)
from .color import require_supported_color
from .errors import DomainError
from .media import check_cancelled, create_proxy, probe_media
from .media_jobs import validate_proxy
from .models import Media, Project
from .package_archive import DEFAULT_LIMITS, MIB, PackageArchive, PackageLimits, invalid
from .storage import ProjectStore, StorageError, atomic_json, require_uuid, utc_now

Progress = Callable[[str, int, int | None], None]


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode()


def read_json(data: bytes) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise invalid("Duplicate JSON fields are not allowed in project packages.")
            result[key] = value
        return result

    try:
        value = json.loads(
            data, object_pairs_hook=unique, parse_constant=lambda _value: (_ for _ in ()).throw(ValueError())
        )
        if not isinstance(value, dict):
            raise ValueError()

        def check_depth(item, depth=0):
            if depth > 64:
                raise invalid("The package JSON is too deeply nested.")
            if isinstance(item, dict):
                for child in item.values():
                    check_depth(child, depth + 1)
            elif isinstance(item, list):
                for child in item:
                    check_depth(child, depth + 1)

        check_depth(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise invalid("The package metadata is not valid JSON.") from error


def manifest(archive: PackageArchive, cancel: threading.Event | None = None) -> tuple[dict, Project, bytes]:
    raw_manifest, _ = archive.metadata("manifest.json", cancel)
    value = read_json(raw_manifest)
    if value.get("format") != "bjjproj" or type(value.get("version")) is not int or value["version"] != 1:
        raise DomainError(
            "PACKAGE_UNSUPPORTED", "This project package needs a newer app or uses another format.", 422
        )
    raw_project, project_hash = archive.metadata("project.json", cancel)
    try:
        project = Project.model_validate(read_json(raw_project))
    except ValidationError as error:
        raise invalid("The project document is invalid.") from error
    try:
        header = value["project"]
        if (
            header["entry"] != "project.json"
            or header["sha256"] != project_hash
            or type(header["byteSize"]) is not int
            or header["byteSize"] != len(raw_project)
        ):
            raise invalid("The project document failed checksum verification.")
        include_proxy = value["includeProxy"]
        if type(include_proxy) is not bool:
            raise ValueError()
        expected = required_assets(project, proxy=include_proxy)
        if project.source.asset == project.proxy.asset or any(
            clip.asset in (project.source.asset, project.proxy.asset) for clip in project.voiceovers
        ):
            raise ValueError()
        entries = value["assets"]
        if not isinstance(entries, list) or len(entries) != len(expected):
            raise invalid("The package is missing required media.")
        refs, identifiers, names = set(), set(), {"manifest.json", "project.json"}
        for entry in entries:
            identifier = require_uuid(entry["assetId"])
            ref, name = entry["reference"], entry["entry"]
            if (
                identifier in identifiers
                or ref in refs
                or ref not in expected
                or name != f"assets/{identifier}"
                or name not in archive.entries
                or entry["kind"] != expected[ref][0]
                or (
                    Media.model_validate(entry["metadata"]).model_dump(mode="json")
                    if entry["kind"] in ("source", "proxy")
                    else entry["metadata"]
                )
                != expected[ref][1]
                or type(entry["byteSize"]) is not int
                or entry["byteSize"] != archive.entries[name].file_size
                or not isinstance(entry["sha256"], str)
                or not re.fullmatch("[0-9a-f]{64}", entry["sha256"])
            ):
                raise invalid("The package asset inventory is inconsistent.")
            # References are never used as extraction paths. Installation assigns
            # fresh generated filenames, also avoiding Windows/Unicode collisions.
            refs.add(ref)
            identifiers.add(identifier)
            names.add(name)
        if names != archive.entries.keys():
            raise invalid("The package contains undeclared media or extra files.")
    except (KeyError, TypeError, ValueError, StorageError) as error:
        if isinstance(error, DomainError):
            raise
        raise invalid("The package asset inventory is damaged.") from error
    return value, project, raw_project


def package_estimate(store: ProjectStore, project: Project, include_proxy: bool) -> dict:
    total = sum(
        immutable_file(store.project_dir(project.projectId), ref).stat().st_size
        for ref in required_assets(project, proxy=include_proxy)
    )
    return space_estimate("backup", output=total + len(json_bytes(project.model_dump(mode="json"))) + MIB)


def backup(
    store: ProjectStore,
    project: Project,
    output: Path,
    include_proxy: bool,
    cancel: threading.Event,
    progress: Progress,
    limits: PackageLimits = DEFAULT_LIMITS,
) -> None:
    """Caller leases the snapshot's project until this operation completes."""
    progress("inspecting", 0, None)
    require_space(output.parent, package_estimate(store, project, include_proxy))
    entries = [
        {**entry, "entry": f"assets/{entry['assetId']}"}
        for entry in manifest_assets(store, project, proxy=include_proxy, cancel=cancel)
    ]
    document = json_bytes(project.model_dump(mode="json"))
    value = {
        "format": "bjjproj",
        "version": 1,
        "includeProxy": include_proxy,
        "project": {
            "entry": "project.json",
            "sha256": hashlib.sha256(document).hexdigest(),
            "byteSize": len(document),
        },
        "assets": entries,
    }
    header = json_bytes(value)
    total = sum(entry["byteSize"] for entry in entries) + len(document) + len(header)
    if (
        total > min(limits.expanded, limits.compressed)
        or any(entry["byteSize"] > limits.per_file for entry in entries)
        or max(len(header), len(document)) > limits.metadata
    ):
        raise invalid("This project exceeds the supported portable package size.")
    done = 0
    completed = created = False
    try:
        handle = output.open("xb")
        created = True
        with handle, zipfile.ZipFile(handle, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            for name, data in [("manifest.json", header), ("project.json", document)]:
                info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                with archive.open(info, "w", force_zip64=True) as target:
                    check_cancelled(cancel)
                    target.write(data)
                    done += len(data)
            for entry in entries:
                path = immutable_file(store.project_dir(project.projectId), entry["reference"])
                info = zipfile.ZipInfo(entry["entry"], date_time=(2000, 1, 1, 0, 0, 0))
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                digest, size = hashlib.sha256(), 0
                with path.open("rb") as source, archive.open(info, "w", force_zip64=True) as target:
                    while chunk := source.read(MIB):
                        check_cancelled(cancel)
                        size += len(chunk)
                        done += len(chunk)
                        if size > entry["byteSize"]:
                            raise invalid("A media asset changed during backup.")
                        target.write(chunk)
                        digest.update(chunk)
                        progress("packing", done, total)
                if size != entry["byteSize"] or digest.hexdigest() != entry["sha256"]:
                    raise DomainError(
                        "ASSET_CHANGED",
                        "A media asset changed during backup. Its original was preserved.",
                        409,
                    )
        # Re-read the finished ZIP incrementally before advertising it as usable.
        progress("validating", 0, total)
        reader = PackageArchive(output, limits)
        verified, _, _ = manifest(reader, cancel)
        checked = 0
        for entry in verified["assets"]:

            def consume(data: bytes) -> None:
                nonlocal checked
                checked += len(data)
                progress("validating", checked, total)

            if reader.stream(entry["entry"], consume, cancel) != entry["sha256"]:
                raise invalid("The written backup failed checksum verification.")
        with output.open("r+b") as handle:
            os.fsync(handle.fileno())
        completed = True
    finally:
        if created and not completed:
            output.unlink(missing_ok=True)


def remap_copy(project: Project, project_id: str) -> tuple[dict, dict[str, str]]:
    mapping = {
        project.projectId: project_id,
        **{item.id: str(uuid4()) for item in [*project.annotations, *project.voiceovers]},
    }
    refs = {
        project.source.asset: f"source/{uuid4()}{safe_extension(project.source.asset)}",
        project.proxy.asset: f"proxy/{uuid4()}.mp4",
    }
    refs.update({clip.asset: f"voiceover/{mapping[clip.id]}.wav" for clip in project.voiceovers})
    mapping.update(refs)
    literals = {"text", "projectName", "originalFilename", "label", "note", "name"}

    def rewrite(value):
        if isinstance(value, str):
            return mapping.get(value, value)
        if isinstance(value, list):
            return [rewrite(item) for item in value]
        if isinstance(value, dict):
            return {key: item if key in literals else rewrite(item) for key, item in value.items()}
        return value

    document = rewrite(project.model_dump(mode="json"))
    document.update(
        revision=1,
        projectName=project.projectName[:144] + " (restored copy)",
        createdAt=utc_now(),
        updatedAt=utc_now(),
    )
    return document, mapping


def safe_extension(reference: str) -> str:
    extension = Path(reference).suffix.lower()
    return extension if re.fullmatch(r"\.[a-z0-9]{1,10}", extension) else ".mp4"


def validate_recording(path: Path, clip, cancel: threading.Event) -> None:
    try:
        with wave.open(str(path), "rb") as audio:
            if (
                clip.codec != "pcm_s16le"
                or audio.getframerate() != clip.sampleRate
                or audio.getnchannels() != clip.channels
                or audio.getsampwidth() != 2
                or abs(audio.getnframes() / audio.getframerate() - clip.durationSec)
                > 1 / audio.getframerate()
            ):
                raise invalid("A recording does not match its saved duration or audio format.")
            expected = audio.getnframes() * audio.getnchannels() * audio.getsampwidth()
            actual = 0
            while data := audio.readframes(MIB // (audio.getnchannels() * audio.getsampwidth())):
                check_cancelled(cancel)
                actual += len(data)
            if expected != actual:
                raise invalid("A recording is truncated.")
    except (wave.Error, EOFError) as error:
        raise invalid("A required recording is damaged.") from error


def restore(
    store: ProjectStore,
    archive_path: Path,
    staging: Path,
    project_id: str,
    cancel: threading.Event,
    progress: Progress,
    limits: PackageLimits = DEFAULT_LIMITS,
    publish: Callable[[Path, Project], Project] | None = None,
) -> Project:
    progress("inspecting", 0, None)
    reader = PackageArchive(archive_path, limits)
    value, original, raw_project = manifest(reader, cancel)
    total = sum(entry["byteSize"] for entry in value["assets"])
    estimate = space_estimate(
        "restore",
        incoming=total,
        output=0 if value["includeProxy"] else proxy_estimate(original.source.durationSec)["requiredBytes"],
    )
    require_space(archive_path.parent, estimate)
    staging.mkdir(exist_ok=False)
    copied = 0
    try:
        stage_store = ProjectStore(staging)
        folder = stage_store.create_dir(project_id)
        document, mapping = remap_copy(original, project_id)
        for entry in value["assets"]:
            target = folder / mapping[entry["reference"]]
            digest = None
            with target.open("xb") as handle:

                def consume(data: bytes) -> None:
                    nonlocal copied
                    handle.write(data)
                    copied += len(data)
                    progress("extracting", copied, total)

                digest = reader.stream(entry["entry"], consume, cancel)
                handle.flush()
                os.fsync(handle.fileno())
            if digest != entry["sha256"]:
                raise invalid("A required media asset failed SHA-256 verification.")
        progress("validating", 0, None)
        source = probe_media(
            folder / document["source"]["asset"],
            document["source"]["asset"],
            original.source.originalFilename,
            cancel,
        )
        require_supported_color(source.model_dump(mode="json"))
        if (
            abs(source.durationSec - original.source.durationSec) > 0.001
            or abs(source.videoStartSec - original.source.videoStartSec) > 0.001
            or (source.displayWidth, source.displayHeight)
            != (original.source.displayWidth, original.source.displayHeight)
        ):
            raise invalid("The source does not match its saved timing or orientation.")
        # AVFoundation track IDs are not FFmpeg stream selectors. Resolve these
        # device-specific decode indices for the newly installed asset copy.
        document["source"].update(
            videoStreamIndex=source.videoStreamIndex, audioStreamIndex=source.audioStreamIndex
        )
        proxy_ref = document["proxy"]["asset"]
        proxy_path = folder / proxy_ref
        if not value["includeProxy"]:
            progress("preparing_preview", 0, None)
            create_proxy(
                folder / source.asset,
                proxy_path,
                source,
                cancel,
                lambda seconds: progress(
                    "preparing_preview", round(seconds * 1000), round(source.durationSec * 1000)
                ),
            )
            document["proxy"] = validate_proxy(
                source, probe_media(proxy_path, proxy_ref, "preview.mp4", cancel)
            ).model_dump(mode="json")
        else:
            validate_proxy(source, probe_media(proxy_path, proxy_ref, "preview.mp4", cancel))
        project = Project.model_validate(document)
        for clip in project.voiceovers:
            validate_recording(folder / clip.asset, clip, cancel)
            atomic_json(folder / "voiceover" / f"{clip.id}.json", clip.model_dump(mode="json"))
        # Preserve exact pre-migration bytes and a complete old/new reference map.
        (folder / "package-original-project.json").write_bytes(raw_project)
        atomic_json(folder / "package-original-manifest.json", value)
        atomic_json(folder / "package-reference-map.json", {"version": 1, "references": mapping})
        saved = stage_store.save(project, existing=False)
        reopened = stage_store.load(saved.projectId)
        manifest_assets(stage_store, reopened, proxy=True, cancel=cancel)
        check_cancelled(cancel)
        return publish(folder, reopened) if publish else install(store, folder, reopened, cancel)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def install(store: ProjectStore, folder: Path, project: Project, cancel: threading.Event) -> Project:
    with store.lock:
        check_cancelled(cancel)
        target = store.project_dir(project.projectId)
        if target.exists():
            raise DomainError(
                "PROJECT_CONFLICT",
                "A project with this new identifier already exists. Restore again to create another copy.",
                409,
            )
        os.rename(folder, target)
        try:
            return store.load(project.projectId)
        except BaseException:
            os.rename(target, folder)
            raise
