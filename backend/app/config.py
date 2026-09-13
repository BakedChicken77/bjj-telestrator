"""Local defaults. One server process owns the project and export directories."""
import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Config:
    data_dir: Path = field(default_factory=lambda: Path(os.getenv('BJJ_DATA_DIR', str(ROOT / 'data'))).resolve())
    frontend_dir: Path = field(default_factory=lambda: Path(os.getenv('BJJ_FRONTEND_DIR', str(ROOT / 'frontend' / 'dist'))).resolve())
    max_upload_bytes: int = field(default_factory=lambda: int(os.getenv('BJJ_MAX_UPLOAD_BYTES', str(4 * 1024**3))))
    max_voiceover_bytes: int = field(default_factory=lambda: int(os.getenv('BJJ_MAX_VOICEOVER_BYTES', str(512 * 1024**2))))
    max_package_bytes: int = field(default_factory=lambda: int(os.getenv('BJJ_MAX_PACKAGE_BYTES', str(16 * 1024**3))))
    max_package_expanded_bytes: int = field(default_factory=lambda: int(os.getenv('BJJ_MAX_PACKAGE_EXPANDED_BYTES', str(16 * 1024**3))))
    export_workers: int = field(default_factory=lambda: int(os.getenv('BJJ_EXPORT_WORKERS', '1')))
    allowed_origins: tuple[str, ...] = field(default_factory=lambda: tuple(os.getenv(
        'BJJ_ALLOWED_ORIGINS', 'http://localhost:8000,http://127.0.0.1:8000,http://localhost:5173,http://127.0.0.1:5173'
    ).split(',')))
    allowed_hosts: tuple[str, ...] = ('localhost', '127.0.0.1', '[::1]')
