"""Versioned immutable job input. Retry always starts at zero on this revision."""
from __future__ import annotations

import json
import re
import threading
from pathlib import Path

from .assets import digest_file, immutable_file, manifest_assets, required_assets
from .errors import DomainError
from .models import Project
from .storage import ProjectStore, StorageError, require_uuid


def output_contract(project: Project) -> dict:
    from .color import HDR_CAPABILITY
    from .renderer import output_dimensions
    width, height = output_dimensions(project.source)
    return {'startSec': 0, 'endSec': project.source.durationSec,
            'width': width, 'height': height,
            'fps': project.exportSettings.fps, 'quality': project.exportSettings.model_dump(mode='json'),
            'container': 'mp4', 'videoCodec': 'h264', 'audioCodec': 'aac', 'pixelFormat': 'yuv420p',
            'colorPolicy': 'hdr-rec709-v1' if HDR_CAPABILITY in project.requiredCapabilities else 'supported-sdr-v1',
            'audioPolicy': 'linear-mix-v1'}


def build_plan(store: ProjectStore, project: Project) -> dict:
    return {'version': 1, 'projectId': project.projectId, 'revision': project.revision,
            'requiredCapabilities': project.requiredCapabilities, 'output': output_contract(project),
            'project': project.model_dump(mode='json'), 'assets': manifest_assets(store, project)}


def read_plan(path: Path, project_id: str, revision: int | None) -> dict:
    try:
        if path.stat().st_size > 32 * 1024**2:
            raise ValueError()
        plan = json.loads(path.read_bytes())
        project = validate_plan(plan, project_id, revision)
        if project.schemaVersion != plan['project']['schemaVersion']:
            raise ValueError()  # A retry cannot silently migrate its immutable input.
        return plan
    except FileNotFoundError as exc:
        raise DomainError('EXPORT_INPUT_MISSING', 'This older export has no saved retry input. Render the current review instead.', 409) from exc
    except (ValueError, KeyError, TypeError, StorageError) as exc:
        if isinstance(exc, DomainError):
            raise
        raise DomainError('EXPORT_INPUT_INVALID', 'This export input is damaged or unsupported. Its media was preserved.', 409) from exc


def validate_plan(plan: dict, project_id: str, revision: int | None) -> Project:
    project = Project.model_validate(plan['project'])
    if (project.schemaVersion != plan['project']['schemaVersion']
            or type(plan['version']) is not int or plan['version'] != 1
            or type(plan['revision']) is not int or plan['projectId'] != project_id or project.projectId != project_id
            or plan['revision'] != revision or project.revision != revision
            or plan['requiredCapabilities'] != project.requiredCapabilities or plan['output'] != output_contract(project)):
        raise ValueError('Export input does not match its revision or output contract')
    expected = required_assets(project)
    assets = plan['assets']
    if not isinstance(assets, list) or len(assets) != len(expected):
        raise ValueError('Invalid asset list')
    refs, identifiers = set(), set()
    for entry in assets:
        reference = entry['reference']
        identifier = require_uuid(entry['assetId'])
        if (reference not in expected or reference in refs or identifier in identifiers
                or entry['kind'] != expected[reference][0] or entry['metadata'] != expected[reference][1]
                or type(entry['byteSize']) is not int or entry['byteSize'] < 1
                or not isinstance(entry['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', entry['sha256'])):
            raise ValueError('Invalid asset identity')
        refs.add(reference)
        identifiers.add(identifier)
    return project


def verify_assets(folder: Path, plan: dict, cancelled: threading.Event | None = None) -> None:
    for entry in plan['assets']:
        path = immutable_file(folder, entry['reference'])
        if path.stat().st_size != entry['byteSize'] or digest_file(path, cancelled) != entry['sha256']:
            raise DomainError('ASSET_CHANGED', 'An asset differs from this export’s original input. Restore the matching media before retrying.', 409)
