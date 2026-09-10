"""Regenerate project-format reference JSON with the backend environment."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from app.models import Project  # noqa: E402


def main() -> None:
    now = "2026-09-05T12:00:00Z"
    metadata = {
        "asset": "source/00000000-0000-4000-8000-000000000002.mp4",
        "originalFilename": "rolling.mp4", "durationSec": 20,
        "codec": "h264", "audioCodec": "aac", "hasAudio": True,
        "codedWidth": 1920, "codedHeight": 1080,
        "displayWidth": 1920, "displayHeight": 1080,
        "sampleAspectRatio": "1:1", "displayAspectRatio": "16:9",
        "rotation": 0, "avgFrameRate": 30,
    }
    project = Project.model_validate({
        "schemaVersion": 1,
        "projectId": "00000000-0000-4000-8000-000000000001",
        "projectName": "Guard retention review",
        "createdAt": now, "updatedAt": now,
        "source": metadata,
        "proxy": {**metadata, "asset": "proxy/00000000-0000-4000-8000-000000000003.mp4"},
        "annotations": [{
            "id": "00000000-0000-4000-8000-000000000004",
            "type": "arrow", "startSec": 5, "endSec": 10, "zIndex": 1,
            "strokeColor": "#ff3333", "strokeWidth": 0.006,
            "strokeOpacity": 1, "fillColor": "#ff3333", "fillOpacity": 0,
            "geometry": {"x1": 0.25, "y1": 0.5, "x2": 0.75, "y2": 0.5,
                         "arrowheadSize": 0.025},
            "createdAt": now, "updatedAt": now,
        }],
        "voiceovers": [],
    })
    destination = ROOT / "docs"
    destination.mkdir(exist_ok=True)
    (destination / "project.schema.json").write_text(
        json.dumps(Project.model_json_schema(), indent=2) + "\n", encoding="utf-8")
    (destination / "example-project.json").write_text(
        project.model_dump_json(indent=2) + "\n", encoding="utf-8")
    print("Updated docs/project.schema.json and docs/example-project.json")


if __name__ == "__main__":
    main()
