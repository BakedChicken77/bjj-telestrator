"""Generate deterministic local media for editor and export acceptance tests."""

import argparse
import json
import subprocess
from pathlib import Path


def generate(output: Path, duration: float = 20, portrait: bool = False,
             audio: bool = True, rotation: bool = False) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    size = "360x640" if portrait else "640x360"
    intermediate = output.with_name(output.stem + "-unrotated.mp4") if rotation else output
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", f"color=c=0x183044:s={size}:r=30:d={duration}"]
    if audio:
        args += ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:duration={duration}"]
    args += ["-vf", "drawgrid=width=80:height=60:thickness=1:color=0x456078@0.6",
             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
    if audio:
        args += ["-c:a", "aac", "-b:a", "128k"]
    args += ["-t", str(duration), "-movflags", "+faststart", str(intermediate)]
    subprocess.run(args, check=True)
    if rotation:
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i",
                        str(intermediate), "-c", "copy", "-metadata:s:v:0", "rotate=90",
                        str(output)], check=True)
        def read_rotation() -> float:
            result = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of",
                                     "json", str(output)], check=True, capture_output=True, text=True)
            video = next(stream for stream in json.loads(result.stdout)["streams"]
                         if stream["codec_type"] == "video")
            return float(next((side["rotation"] for side in video.get("side_data_list", [])
                               if "rotation" in side), video.get("tags", {}).get("rotate", 0)))
        if read_rotation() % 360 != 90:
            # Recent FFmpeg uses a display matrix override instead of the legacy tag.
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-display_rotation:v:0", "90", "-i", str(intermediate),
                            "-c", "copy", str(output)], check=True)
        if read_rotation() % 360 != 90:
            raise RuntimeError("FFmpeg did not write the requested rotation test metadata")
        intermediate.unlink()
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path,
                        default=Path("tests/generated/acceptance.mp4"))
    parser.add_argument("--duration", type=float, default=20)
    parser.add_argument("--portrait", action="store_true")
    parser.add_argument("--silent", action="store_true")
    parser.add_argument("--rotation", action="store_true")
    options = parser.parse_args()
    print(generate(options.output, options.duration, options.portrait,
                   not options.silent, options.rotation))
