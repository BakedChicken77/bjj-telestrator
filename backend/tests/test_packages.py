"""Cross-platform package contract and adversarial extraction with real media."""

import base64
import errno
import json
import stat
import struct
import threading
import wave
import zipfile
from dataclasses import replace
from pathlib import Path
from uuid import uuid4

import pytest
from test_media_jobs import media as media

from app.assets import digest_file
from app.errors import DomainError
from app.models import Project, Voiceover
from app.package_archive import DEFAULT_LIMITS, PackageArchive
from app.packages import backup, json_bytes, restore
from app.renderer import render_export
from app.storage import ProjectStore, utc_now
from test_backend import raw_project

FIXTURE = json.loads((Path(__file__).resolve().parents[2] / 'tests/fixtures/package-conformance.json').read_text())


@pytest.mark.parametrize('case', FIXTURE['cases'], ids=lambda case: case['name'])
def test_shared_package_conformance(case, tmp_path):
    archive = tmp_path / 'fixture.bjjproj'
    archive.write_bytes(base64.b64decode(case['archiveBase64']))
    store = ProjectStore(tmp_path / 'device')
    identifier = str(uuid4())
    def attempt():
        return restore(store, archive, tmp_path / 'staging', identifier, threading.Event(), lambda *_: None)
    if case['valid']:
        project = attempt()
        folder = store.project_dir(project.projectId)
        assert digest_file(folder / project.source.asset) == FIXTURE['sourceSHA256']
        assert digest_file(folder / project.voiceovers[0].asset) == FIXTURE['voiceoverSHA256']
        assert project.annotations[0].startSec == .5 and project.annotations[0].endSec == 1.5
        assert project.voiceovers[0].startSec == .75 and project.voiceovers[0].endSec == 1
    else:
        with pytest.raises(DomainError):
            attempt()
        assert not store.project_dir(identifier).exists()
    assert not (tmp_path / 'staging').exists()


@pytest.fixture
def populated(media, tmp_path):
    app, _client, project, original, _job = media
    identifier = str(uuid4())
    path = tmp_path / "narration.wav"
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(48000)
        wav.writeframes(struct.pack("<h", 6000) * 24000)
    clip = Voiceover(
        id=identifier,
        asset=f"voiceover/{identifier}.wav",
        startSec=0.5,
        durationSec=0.5,
        endSec=1,
        codec="pcm_s16le",
        sampleRate=48000,
        channels=1,
        recordedAt=utc_now(),
    )
    app.state.store.register_voiceover(project.projectId, clip, path)
    doc = project.model_dump(mode="json")
    doc["voiceovers"] = [clip.model_dump(mode="json")]
    cue = raw_project()["annotations"][0]
    cue.update(startSec=0.5, endSec=1.5)
    doc["annotations"] = [cue]
    doc["futureOptional"] = {"annotationRef": cue["id"], "note": cue["id"]}
    saved = app.state.store.save(Project.model_validate(doc))
    return app.state.store, saved, original


@pytest.mark.integration
@pytest.mark.parametrize("include_proxy", [False, True])
def test_real_package_round_trip_is_editable_and_source_is_immutable(populated, tmp_path, include_proxy):
    store, project, original = populated
    path = tmp_path / "review.bjjproj"
    events = []
    def progress(*event):
        events.append(event)
    backup(store, project, path, include_proxy, threading.Event(), progress)
    with zipfile.ZipFile(path) as archive:
        assert all(entry.compress_type == zipfile.ZIP_STORED for entry in archive.infolist())
        assert len(archive.infolist()) == 4 + int(include_proxy)
    copy = restore(store, path, tmp_path / "stage", str(uuid4()), threading.Event(), progress)
    assert copy.projectId != project.projectId and copy.revision == 1
    assert copy.annotations[0].id != project.annotations[0].id
    assert copy.voiceovers[0].id != project.voiceovers[0].id
    assert copy.annotations[0].geometry == project.annotations[0].geometry
    assert copy.annotations[0].startSec == 0.5 and copy.annotations[0].endSec == 1.5
    assert copy.model_extra["futureOptional"]["annotationRef"] == copy.annotations[0].id
    assert copy.model_extra["futureOptional"]["note"] == project.annotations[0].id
    folder = store.project_dir(copy.projectId)
    assert digest_file(folder / copy.source.asset) == digest_file(original)
    assert digest_file(folder / copy.voiceovers[0].asset) == digest_file(
        store.project_dir(project.projectId) / project.voiceovers[0].asset
    )
    assert store.load(project.projectId).revision == project.revision
    assert not (tmp_path / "stage").exists()
    assert any(event[0] == "preparing_preview" for event in events) == (not include_proxy)
    changed = copy.model_copy(update={"projectName": "Edited restored copy"})
    saved = store.save(changed)
    output = tmp_path / "output.mp4"
    render_export(saved, folder, output, tmp_path / "render", lambda _seconds: None, threading.Event())
    assert output.stat().st_size > 1000
    assert ProjectStore(store.root.parent).load(copy.projectId).projectName == "Edited restored copy"
    second = tmp_path / "second.bjjproj"
    backup(store, saved, second, False, threading.Event(), progress)
    other = ProjectStore(tmp_path / "other-device")
    again = restore(other, second, tmp_path / "second-stage", str(uuid4()), threading.Event(), progress)
    assert again.annotations[0].geometry == project.annotations[0].geometry
    assert digest_file(other.project_dir(again.projectId) / again.source.asset) == digest_file(original)


def minimal_archive(path, name="project.json", data=b"{}", method=zipfile.ZIP_STORED):
    with zipfile.ZipFile(path, "w", compression=method) as archive:
        archive.writestr("manifest.json", b"{}")
        archive.writestr(name, data)


@pytest.mark.parametrize(
    "name",
    [
        "../project.json",
        "/project.json",
        "C:/project.json",
        "assets/../project.json",
        "PROJECT.JSON",
        "proj\u0435ct.json",
        "pr\u006fj\u0065ct.json.",
        "project.json/child",
        "project.json\x00ignored",
        "CON",
        "assets\\evil",
    ],
)
def test_nonportable_archive_names_are_rejected_before_extraction(tmp_path, name):
    path = tmp_path / "unsafe.zip"
    minimal_archive(path, name)
    if "\0" in name:
        # zipfile strips NULs on writing; insert one into both serialized names.
        raw = path.read_bytes().replace(b"project.json", b"project.jso\0")
        path.write_bytes(raw)
    with pytest.raises(DomainError):
        PackageArchive(path)


def test_duplicate_symlink_encryption_and_overlapping_entries_are_rejected(tmp_path):
    for variant in ("duplicate", "symlink", "encrypted", "overlap"):
        path = tmp_path / f"{variant}.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("manifest.json", "{}")
            entry = zipfile.ZipInfo("project.json")
            if variant == "symlink":
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "{}")
            if variant == "duplicate":
                with pytest.warns(UserWarning, match="Duplicate name"):
                    archive.writestr("project.json", "{}")
        if variant in ("encrypted", "overlap"):
            raw = bytearray(path.read_bytes())
            central = raw.find(b"PK\x01\x02")
            if variant == "encrypted":
                struct.pack_into("<H", raw, 6, 1)
                struct.pack_into("<H", raw, central + 8, 1)
            else:
                second = raw.find(b"PK\x01\x02", central + 4)
                struct.pack_into("<I", raw, second + 42, 0)
            path.write_bytes(raw)
        with pytest.raises(DomainError):
            PackageArchive(path)


def test_deflate_actual_expansion_is_measured_not_trusted(tmp_path):
    path = tmp_path / "bomb.zip"
    minimal_archive(path, data=b"x" * 200_000, method=zipfile.ZIP_DEFLATED)
    with pytest.raises(DomainError):
        PackageArchive(path, replace(DEFAULT_LIMITS, metadata=1000))
    raw = bytearray(path.read_bytes())
    central = raw.find(b"PK\x01\x02", raw.find(b"PK\x01\x02") + 4)
    local = struct.unpack_from("<I", raw, central + 42)[0]
    struct.pack_into("<I", raw, central + 24, 100)
    struct.pack_into("<I", raw, local + 22, 100)
    path.write_bytes(raw)
    archive = PackageArchive(path)
    received = []
    with pytest.raises(DomainError, match="Actual ZIP expansion"):
        archive.stream("project.json", received.append)
    assert sum(map(len, received)) <= 100


def test_zip64_directory_and_entry_headers_are_accepted_with_bounded_data(tmp_path):
    path = tmp_path / "zip64.zip"
    with zipfile.ZipFile(path, "w", allowZip64=True) as archive:
        for name in ("manifest.json", "project.json"):
            with archive.open(name, "w", force_zip64=True) as entry:
                entry.write(b"{}")
    raw = path.read_bytes()
    end = len(raw) - 22
    _, _, _, count, _, length, offset, _ = struct.unpack("<4s4H2IH", raw[end:])
    large = struct.pack("<4sQ2H2I4Q", b"PK\x06\x06", 44, 45, 45, 0, 0, count, count, length, offset)
    locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, end, 1)
    tail = struct.pack("<4s4H2IH", b"PK\x05\x06", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    path.write_bytes(raw[:end] + large + locator + tail)
    assert PackageArchive(path).metadata("project.json")[0] == b"{}"


@pytest.mark.parametrize("action", ["cancel", "checksum", "install_failure"])
def test_restore_failure_preserves_existing_project_and_removes_staging(populated, tmp_path, action):
    store, project, original = populated
    path = tmp_path / "review.bjjproj"
    backup(store, project, path, True, threading.Event(), lambda *_args: None)
    cancel = threading.Event()

    def progress(stage, _done, _total):
        if stage == "extracting" and action == "cancel":
            cancel.set()

    if action == "checksum":
        with zipfile.ZipFile(path) as archive:
            contents = {entry.filename: archive.read(entry) for entry in archive.infolist()}
        value = json.loads(contents["manifest.json"])
        value["assets"][0]["sha256"] = "0" * 64
        contents["manifest.json"] = json_bytes(value)
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in contents.items():
                archive.writestr(name, data)

    def publish(_folder, _project):
        raise OSError(errno.ENOSPC, "injected storage failure")

    with pytest.raises((DomainError, OSError)):
        restore(
            store,
            path,
            tmp_path / "failed-stage",
            str(uuid4()),
            cancel,
            progress,
            publish=publish if action == "install_failure" else None,
        )
    assert not (tmp_path / "failed-stage").exists()
    assert store.load(project.projectId).revision == project.revision
    assert digest_file(store.project_dir(project.projectId) / project.source.asset) == digest_file(original)
