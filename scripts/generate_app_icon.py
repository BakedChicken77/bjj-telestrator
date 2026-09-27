"""Rasterize the application's existing stacked-mats mark for the iOS asset catalog.

Uses Pillow from backend/requirements.txt. Output is opaque and antialiased.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    image = Image.new("RGB", (2048, 2048), "#101820")
    draw = ImageDraw.Draw(image)
    scale, origin = 47, 272
    paths = [
        [(4, 9), (16, 3), (28, 9), (16, 15), (4, 9)],
        [(4, 15), (16, 21), (28, 15)],
        [(4, 21), (16, 27), (28, 21)],
    ]
    for path in paths:
        draw.line(
            [(origin + x * scale, origin + y * scale) for x, y in path],
            fill="#bded7a",
            width=94,
            joint="curve",
        )
    target = ROOT / "frontend/ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"
    image.resize((1024, 1024), Image.Resampling.LANCZOS).save(target)
    splash_folder = target.parent.parent / "Splash.imageset"
    splash = Image.new("RGB", (2732, 2732), "#101820")
    splash.paste(image.resize((560, 560), Image.Resampling.LANCZOS), (1086, 1086))
    for item in json.loads((splash_folder / "Contents.json").read_text())["images"]:
        if "filename" in item:
            splash.save(splash_folder / item["filename"])
    print(f"Updated {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
