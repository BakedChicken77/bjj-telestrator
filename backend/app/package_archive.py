"""Bounded ZIP/ZIP64 reader for the deliberately small portable archive grammar.

Only manifest.json, project.json and assets/<lowercase UUID> are accepted. This
excludes traversal, OS-reserved names and Unicode/case confusables before any
filesystem write. Deflate output is counted independently of ZIP size claims.
"""

from __future__ import annotations

import hashlib
import re
import stat
import struct
import threading
import zipfile
import zlib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .errors import DomainError
from .media import check_cancelled

MIB = 1024**2
NAME = re.compile(
    r"(?:manifest\.json|project\.json|assets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\Z"
)


@dataclass(frozen=True)
class PackageLimits:
    compressed: int = 16 * 1024**3
    expanded: int = 16 * 1024**3
    per_file: int = 4 * 1024**3
    files: int = 512
    metadata: int = 32 * MIB
    directory: int = MIB


DEFAULT_LIMITS = PackageLimits()


def invalid(message: str = "The project package is damaged or contains unsafe entries.") -> DomainError:
    return DomainError("PACKAGE_INVALID", message, 422)


def read_at(handle, offset: int, count: int) -> bytes:
    if offset < 0 or count < 0:
        raise invalid()
    handle.seek(offset)
    result = handle.read(count)
    if len(result) != count:
        raise invalid("The project package is incomplete.")
    return result


def directory_bounds(path: Path, limits: PackageLimits) -> tuple[int, int]:
    size = path.stat().st_size
    if path.is_symlink() or not 22 <= size <= limits.compressed:
        raise invalid("The package exceeds the supported transfer size or is incomplete.")
    with path.open("rb") as handle:
        tail = read_at(handle, max(0, size - 65557), min(size, 65557))
        position = tail.rfind(b"PK\x05\x06")
        if position < 0 or len(tail) - position < 22:
            raise invalid()
        record = struct.unpack("<4s4H2IH", tail[position : position + 22])
        _, disk, directory_disk, disk_count, count, length, offset, comment = record
        end = size - len(tail) + position
        if disk or directory_disk or disk_count != count or position + 22 + comment != len(tail):
            raise invalid("Split or incomplete ZIP archives are unsupported.")
        if count == 0xFFFF or length == 0xFFFFFFFF or offset == 0xFFFFFFFF:
            locator = struct.unpack("<4sIQI", read_at(handle, end - 20, 20))
            if locator[0] != b"PK\x06\x07" or locator[1] or locator[3] != 1:
                raise invalid()
            large = struct.unpack("<4sQ2H2I4Q", read_at(handle, locator[2], 56))
            if (
                large[0] != b"PK\x06\x06"
                or large[1] != 44
                or large[4]
                or large[5]
                or large[6] != large[7]
                or locator[2] + 56 != end - 20
            ):
                raise invalid("Unsupported ZIP64 directory.")
            count, length, offset, end = large[7], large[8], large[9], locator[2]
        if not 2 <= count <= limits.files or length > limits.directory or offset + length != end:
            raise invalid("The package directory exceeds supported limits or is inconsistent.")
        return offset, count


class PackageArchive:
    def __init__(self, path: Path, limits: PackageLimits = DEFAULT_LIMITS):
        self.path, self.limits = path, limits
        self.expanded = 0
        self.offsets: dict[str, int] = {}
        directory, count = directory_bounds(path, limits)
        try:
            with zipfile.ZipFile(path) as archive, path.open("rb") as handle:
                entries = archive.infolist()
                if len(entries) != count:
                    raise invalid()
                self.entries = {entry.filename: entry for entry in entries}
                if len(self.entries) != count or not {"manifest.json", "project.json"} <= self.entries.keys():
                    raise invalid("The package has duplicate entries or missing metadata.")
                intervals = []
                total = 0
                for entry in entries:
                    if entry.compress_type == 0 and entry.compress_size != entry.file_size:
                        raise invalid("Stored ZIP sizes disagree.")
                    if (
                        not NAME.fullmatch(entry.orig_filename)
                        or entry.orig_filename != entry.filename
                        or entry.flag_bits & ~0x080E
                        or entry.compress_type not in (0, 8)
                        or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG)
                        or entry.is_dir()
                        or entry.volume != 0
                    ):
                        raise invalid(
                            "Encrypted, linked, nonportable or unsupported ZIP entries are not allowed."
                        )
                    limit = limits.metadata if entry.filename.endswith(".json") else limits.per_file
                    if not 0 < entry.file_size <= limit or not 0 < entry.compress_size <= limits.compressed:
                        raise invalid("A package entry exceeds supported size limits.")
                    total += entry.file_size
                    if total > limits.expanded:
                        raise invalid("The package expands beyond the supported size.")
                    local = struct.unpack("<4s5H3I2H", read_at(handle, entry.header_offset, 30))
                    if (
                        local[0] != b"PK\x03\x04"
                        or local[2] != entry.flag_bits
                        or local[3] != entry.compress_type
                    ):
                        raise invalid("ZIP headers disagree.")
                    name = read_at(handle, entry.header_offset + 30, local[9])
                    if name != entry.filename.encode("ascii"):
                        raise invalid("ZIP entry names disagree.")
                    if not entry.flag_bits & 8 and (
                        local[6] != entry.CRC
                        or local[7] not in (entry.compress_size, 0xFFFFFFFF)
                        or local[8] not in (entry.file_size, 0xFFFFFFFF)
                    ):
                        raise invalid("ZIP entry sizes disagree.")
                    offset = entry.header_offset + 30 + local[9] + local[10]
                    stop = offset + entry.compress_size
                    if stop > directory:
                        raise invalid("ZIP data overlaps the directory.")
                    intervals.append((entry.header_offset, stop))
                    self.offsets[entry.filename] = offset
                intervals.sort()
                if any(left[1] > right[0] for left, right in zip(intervals, intervals[1:], strict=False)):
                    raise invalid("ZIP entries overlap.")
        except (zipfile.BadZipFile, UnicodeError, struct.error, OSError, ValueError) as exc:
            if isinstance(exc, DomainError):
                raise
            raise invalid() from exc

    def stream(
        self, name: str, consume: Callable[[bytes], object], cancel: threading.Event | None = None
    ) -> str:
        entry = self.entries[name]
        actual, crc = 0, 0
        digest = hashlib.sha256()

        def write(data: bytes) -> None:
            nonlocal actual, crc
            check_cancelled(cancel)
            actual += len(data)
            self.expanded += len(data)
            if actual > entry.file_size or self.expanded > self.limits.expanded:
                raise invalid("Actual ZIP expansion exceeded its declared or configured limit.")
            crc = zlib.crc32(data, crc)
            digest.update(data)
            consume(data)

        with self.path.open("rb") as handle:
            handle.seek(self.offsets[name])
            remaining = entry.compress_size
            decoder = zlib.decompressobj(-15) if entry.compress_type == 8 else None
            try:
                while remaining:
                    check_cancelled(cancel)
                    chunk = handle.read(min(MIB, remaining))
                    if not chunk:
                        raise invalid("The package transfer is incomplete.")
                    remaining -= len(chunk)
                    if decoder is None:
                        write(chunk)
                    else:
                        while chunk:
                            write(decoder.decompress(chunk, MIB))
                            chunk = decoder.unconsumed_tail
                            if decoder.unused_data or (decoder.eof and remaining):
                                raise invalid("Unexpected bytes follow a compressed entry.")
                if decoder is not None and not decoder.eof:
                    raise invalid("The compressed entry is incomplete.")
            except zlib.error as exc:
                raise invalid("The compressed entry is damaged.") from exc
        if actual != entry.file_size or crc & 0xFFFFFFFF != entry.CRC:
            raise invalid("A package entry failed its size or checksum check.")
        return digest.hexdigest()

    def metadata(self, name: str, cancel: threading.Event | None = None) -> tuple[bytes, str]:
        if name not in ("manifest.json", "project.json"):
            raise invalid()
        data = bytearray()
        digest = self.stream(name, data.extend, cancel)
        return bytes(data), digest
