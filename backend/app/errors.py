"""Stable, safe domain errors shared with the editor and native bridge."""


class DomainError(ValueError):
    def __init__(self, code: str, message: str, status: int = 400, **details: object):
        super().__init__(message)
        self.code, self.status, self.details = code, status, details


def conflict(current_revision: int) -> DomainError:
    return DomainError('PROJECT_CONFLICT',
                       'This project changed in another session. Keep your edits as a copy or reload the saved version.',
                       412, currentRevision=current_revision)
