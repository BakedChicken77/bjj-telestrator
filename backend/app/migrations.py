"""Pure, ordered document migrations. Storage owns backups and installation."""
from __future__ import annotations

from copy import deepcopy

from .errors import DomainError

SCHEMA_VERSION = 2
CAPABILITIES = ('project.revisions.v1',)
MAX_REVISION = 9007199254740991  # JSON/JavaScript safe integer, shared with Swift.


def version_1_to_2(document: dict) -> dict:
    result = deepcopy(document)
    result['schemaVersion'] = 2
    result['revision'] = 1
    result['requiredCapabilities'] = list(dict.fromkeys([
        *result.get('requiredCapabilities', []), 'project.revisions.v1']))
    return result


MIGRATIONS = {1: version_1_to_2}


def migrate_document(value: object) -> dict:
    if not isinstance(value, dict):
        raise DomainError('PROJECT_CORRUPT', 'The project document is damaged.')
    version = value.get('schemaVersion')
    if type(version) is not int or version < 1:
        raise DomainError('PROJECT_CORRUPT', 'The project schema version is invalid.')
    if version > SCHEMA_VERSION:
        raise DomainError('SCHEMA_UNSUPPORTED', 'Upgrade required: this project uses a newer format.', 409)
    capabilities = value.get('requiredCapabilities', [])
    if (not isinstance(capabilities, list) or len(capabilities) > 128
            or any(not isinstance(c, str) or not c or len(c) > 100 for c in capabilities)
            or len(set(capabilities)) != len(capabilities)):
        raise DomainError('PROJECT_CORRUPT', 'The project capability list is invalid.')
    if any(c not in CAPABILITIES for c in capabilities):
        raise DomainError('CAPABILITY_UNSUPPORTED', 'Upgrade required: this project needs unsupported capabilities.', 409)
    result = deepcopy(value)
    while result['schemaVersion'] < SCHEMA_VERSION:
        result = MIGRATIONS[result['schemaVersion']](result)
    if 'project.revisions.v1' not in result.get('requiredCapabilities', []):
        raise DomainError('PROJECT_CORRUPT', 'The project revision capability is missing.')
    if type(result.get('revision')) is not int or not 1 <= result['revision'] <= MAX_REVISION:
        raise DomainError('PROJECT_CORRUPT', 'The project revision is invalid.')
    return result


def runtime_capabilities() -> dict:
    return {'schemaVersion': SCHEMA_VERSION, 'requiredCapabilities': list(CAPABILITIES),
            'conditionalSave': True, 'conditionalExport': True, 'recoveryCopy': True,
            'exportRetry': True, 'storageBreakdown': True, 'exportFileCleanup': True,
            'projectCheckpoints': True, 'projectDuplicate': True, 'projectTrash': True, 'mediaJobs': True, 'proxyRepair': True, 'hdrToSdr': False}
