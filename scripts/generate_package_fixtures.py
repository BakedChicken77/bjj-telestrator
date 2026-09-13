"""Bounded synthetic cross-platform ZIP/ZIP64 project fixtures; no user media."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import struct
import subprocess
import sys
import tempfile
import threading
import wave
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))


def zip_bytes(entries, method=zipfile.ZIP_DEFLATED):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=method) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return buffer.getvalue()


def main():
    from app.media import create_proxy, probe_media
    from app.models import Project, Voiceover
    from app.packages import backup
    from app.storage import ProjectStore

    cases = []

    def add(name, raw, valid):
        cases.append(
            {
                "name": name,
                "valid": valid,
                "archiveBase64": base64.b64encode(raw).decode(),
            }
        )

    with tempfile.TemporaryDirectory(prefix="bjj-package-fixtures-") as directory:
        base = Path(directory)
        store = ProjectStore(base / "device")
        document = json.loads(
            (ROOT / "tests/fixtures/project-conformance.json").read_text()
        )["migrationExpected"]
        folder = store.project_dir(document["projectId"])
        for name in ["source", "proxy", "voiceover", "temp", "exports"]:
            (folder / name).mkdir(parents=True)
        source, proxy = folder / "source/original.mp4", folder / "proxy/editing.mp4"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=blue:s=320x180:r=30:d=2",
                "-c:v",
                "libx264",
                "-threads",
                "2",
                "-pix_fmt",
                "yuv420p",
                str(source),
            ],
            check=True,
        )
        inspected = probe_media(source, "source/original.mp4", "Synthetic blue.mp4")
        create_proxy(source, proxy, inspected)
        document.update(
            source=inspected.model_dump(mode="json"),
            proxy=probe_media(proxy, "proxy/editing.mp4", "Preview.mp4").model_dump(
                mode="json"
            ),
            voiceovers=[],
        )
        document["annotations"] = [
            {**document["annotations"][0], "startSec": 0.5, "endSec": 1.5}
        ]
        document["annotations"][0].update(
            type="rectangle",
            fillOpacity=1,
            geometry={"x": 0.1, "y": 0.1, "width": 0.4, "height": 0.4},
        )
        document.pop("optionalFuture", None)
        initial = store.save(Project.model_validate(document), existing=False)
        identifier = "44444444-4444-4444-8444-444444444444"
        wav = base / "tone.wav"
        with wave.open(str(wav), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(48000)
            handle.writeframes(
                b"".join(
                    struct.pack(
                        "<h", round(6000 * math.sin(2 * math.pi * 880 * i / 48000))
                    )
                    for i in range(12000)
                )
            )
        clip = Voiceover(
            id=identifier,
            asset=f"voiceover/{identifier}.wav",
            startSec=0.75,
            endSec=1,
            durationSec=0.25,
            codec="pcm_s16le",
            sampleRate=48000,
            channels=1,
            recordedAt=document["createdAt"],
        )
        store.register_voiceover(initial.projectId, clip, wav)
        document["voiceovers"] = [clip.model_dump(mode="json")]
        project = store.save(Project.model_validate(document))
        target = base / "fixture.bjjproj"
        backup(store, project, target, True, threading.Event(), lambda *_: None)
        stored = target.read_bytes()
        # The writer emits ZIP64 local headers even for bounded test assets.
        add("stored-with-zip64-local-headers", stored, True)
        end = len(stored) - 22
        _, _, _, count, _, length, offset, _ = struct.unpack("<4s4H2IH", stored[end:])
        large = struct.pack(
            "<4sQ2H2I4Q", b"PK\x06\x06", 44, 45, 45, 0, 0, count, count, length, offset
        )
        locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, end, 1)
        tail = struct.pack(
            "<4s4H2IH", b"PK\x05\x06", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0
        )
        add("zip64-directory", stored[:end] + large + locator + tail, True)
        with zipfile.ZipFile(target) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        compressed = zip_bytes(entries)
        add("deflated", compressed, True)
        omitted = dict(entries)
        manifest = json.loads(omitted["manifest.json"])
        proxy_entry = next(
            item for item in manifest["assets"] if item["kind"] == "proxy"
        )
        manifest["assets"].remove(proxy_entry)
        manifest["includeProxy"] = False
        del omitted[proxy_entry["entry"]]
        omitted["manifest.json"] = json.dumps(manifest).encode()
        add("omitted-proxy", zip_bytes(omitted), True)
        for name in [
            "../project.json",
            "PROJECT.JSON",
            "project.json.",
            "assets/CON",
            "proj\u0435ct.json",
        ]:
            add(
                "unsafe-name-" + name,
                zip_bytes({"manifest.json": b"{}", name: b"{}"}),
                False,
            )
        broken = dict(entries)
        manifest = json.loads(broken["manifest.json"])
        manifest["assets"][0]["sha256"] = "0" * 64
        broken["manifest.json"] = json.dumps(manifest).encode()
        add("hash-mismatch", zip_bytes(broken), False)
        broken = dict(entries)
        broken["manifest.json"] = b'{"version":1,"version":2}'
        add("duplicate-json-key", zip_bytes(broken), False)
        broken = dict(entries)
        unknown = json.loads(broken["project.json"])
        unknown["requiredCapabilities"].append("future.unavailable.v1")
        broken["project.json"] = json.dumps(unknown).encode()
        manifest = json.loads(broken["manifest.json"])
        manifest["project"].update(
            sha256=hashlib.sha256(broken["project.json"]).hexdigest(),
            byteSize=len(broken["project.json"]),
        )
        broken["manifest.json"] = json.dumps(manifest).encode()
        add("unknown-required-capability", zip_bytes(broken), False)
        result = {
            "version": 1,
            "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "voiceoverSHA256": hashlib.sha256(
                (folder / clip.asset).read_bytes()
            ).hexdigest(),
            "durationSec": 2,
            "cases": cases,
        }
        path = ROOT / "tests/fixtures/package-conformance.json"
        path.write_text(json.dumps(result, indent=2) + "\n")
        print(
            f"{len(cases)} bounded fixtures; {path.stat().st_size} bytes; source {result['sourceSHA256']}"
        )


if __name__ == "__main__":
    main()
