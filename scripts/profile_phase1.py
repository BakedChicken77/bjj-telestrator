"""Reproducible local scale workload. Use generated media, never coaching footage.

The default measures 200 metadata records. --export also creates and exports a
20-minute 1080p grid with 100 annotations and three overlapping narration tones.
It is a synthetic stress test, not evidence of real gym footage or phone thermals.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import platform
import struct
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))


def peak_memory():
    try:
        import resource

        factor = 1 if sys.platform == "darwin" else 1024
        return {
            "pythonPeakBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            * factor,
            "childProcessPeakBytes": resource.getrusage(
                resource.RUSAGE_CHILDREN
            ).ru_maxrss
            * factor,
        }
    except ImportError:
        return {"peakMemory": "Record Process Explorer/Task Manager values on Windows."}


def main():
    from app.assets import digest_file
    from app.media import create_proxy, probe_media
    from app.models import Project, Voiceover
    from app.renderer import render_export
    from app.storage import ProjectStore, atomic_json

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, required=True, help="New empty workload directory"
    )
    parser.add_argument(
        "--export", action="store_true", help="Also run the generated 20-minute export"
    )
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=False)
    template = json.loads(
        (ROOT / "tests/fixtures/project-conformance.json").read_text()
    )["migrationExpected"]
    template["voiceovers"] = []
    template["source"]["durationSec"] = template["proxy"]["durationSec"] = 1200
    annotations = []
    for index in range(100):
        cue = copy.deepcopy(template["annotations"][0])
        cue.update(
            id=str(uuid4()), startSec=index * 12, endSec=(index + 1) * 12, zIndex=index
        )
        if index < 20:
            cue.update(
                type="freehand",
                geometry={
                    "points": [
                        {"x": 0.1 + p / 4000, "y": 0.5 + math.sin(p / 20) * 0.2}
                        for p in range(2000)
                    ],
                    "smoothing": 0,
                },
            )
        annotations.append(cue)
    template["annotations"] = annotations
    library = ProjectStore(options.output / "library")
    print("Preparing 200 metadata-only records (no video copies).", flush=True)
    for index in range(200):
        document = {
            **template,
            "projectId": str(uuid4()),
            "projectName": f"Synthetic review {index}",
        }
        atomic_json(
            library.project_dir(document["projectId"]) / "project.json", document
        )
    durations = []
    for _ in range(3):
        started = time.perf_counter()
        records = library.list()
        durations.append(time.perf_counter() - started)
        assert len(records) == 200 and all(
            record["annotationCount"] == 100 for record in records
        )
    report = {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "libraryRecords": 200,
        "annotationsPerRecord": 100,
        "complexPathsPerRecord": 20,
        "pointsPerPath": 2000,
        "libraryListSeconds": durations,
        **peak_memory(),
    }
    if options.export:
        store = ProjectStore(options.output / "export-device")
        identifier = str(uuid4())
        folder = store.create_dir(identifier)
        source = folder / "source/original.mp4"
        proxy = folder / "proxy/preview.mp4"
        print(
            "Generating 20-minute 1080p/30 synthetic grid and source tone.", flush=True
        )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=0x183044:s=1920x1080:r=30:d=1200",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=48000:duration=1200",
                "-vf",
                "drawgrid=width=80:height=60:thickness=1:color=0x456078@0.6",
                "-c:v",
                "libx264",
                "-threads",
                "2",
                "-preset",
                "ultrafast",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                str(source),
            ],
            check=True,
        )
        source_hash = digest_file(source)
        media = probe_media(
            source, "source/original.mp4", "Synthetic 20-minute grid.mp4"
        )
        started = time.perf_counter()
        create_proxy(source, proxy, media)
        report["proxySeconds"] = time.perf_counter() - started
        document = {
            **template,
            "projectId": identifier,
            "source": media.model_dump(mode="json"),
            "proxy": probe_media(proxy, "proxy/preview.mp4", "Preview.mp4").model_dump(
                mode="json"
            ),
        }
        project = store.save(Project.model_validate(document), existing=False)
        clips = []
        for frequency in [660, 880, 1100]:
            clip_id = str(uuid4())
            temporary = options.output / f"{clip_id}.wav"
            chunk = b"".join(
                struct.pack(
                    "<h", round(1800 * math.sin(2 * math.pi * frequency * i / 48000))
                )
                for i in range(48000)
            )
            with wave.open(str(temporary), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(48000)
                for _ in range(1200):
                    wav.writeframesraw(chunk)
            clip = Voiceover(
                id=clip_id,
                asset=f"voiceover/{clip_id}.wav",
                startSec=0,
                endSec=1200,
                durationSec=1200,
                gain=1,
                muted=False,
                timingOffsetMs=0,
                codec="pcm_s16le",
                sampleRate=48000,
                channels=1,
                recordedAt=project.createdAt,
            )
            store.register_voiceover(identifier, clip, temporary)
            clips.append(clip)
        project = store.save(project.model_copy(update={"voiceovers": clips}))
        output = options.output / "review.mp4"
        print(
            "Rendering 100 annotations and three overlapping 20-minute takes.",
            flush=True,
        )
        started = time.perf_counter()
        render_export(
            project,
            folder,
            output,
            options.output / "render-temporary",
            lambda _: None,
            threading.Event(),
        )
        report["exportSeconds"] = time.perf_counter() - started
        final = probe_media(output, "exports/result.mp4", "result.mp4")
        assert (
            final.codec == "h264"
            and final.audioCodec == "aac"
            and abs(final.durationSec - 1200) <= 0.1
        )
        assert digest_file(source) == source_hash
        report.update(
            sourceSHA256=source_hash,
            sourceBytes=source.stat().st_size,
            outputBytes=output.stat().st_size,
            outputSeconds=final.durationSec,
            outputWidth=final.displayWidth,
            outputHeight=final.displayHeight,
            voiceoverCount=3,
            outputVideoCodec=final.codec,
            outputAudioCodec=final.audioCodec,
            **peak_memory(),
        )
    report["limitations"] = (
        "Generated static grid/tones; excludes real-roll complexity, human audio review, signed iPhone memory/thermal behavior and Windows-host acceptance."
    )
    (options.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
