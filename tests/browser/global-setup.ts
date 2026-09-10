import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export default function setup(): void {
  const generated = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../generated",
  );
  fs.mkdirSync(generated, { recursive: true });
  const generator = path.resolve(
    generated,
    "../../scripts/generate_test_video.py",
  );
  const fixtures = [
    { name: "acceptance.mp4", args: ["--duration", "20"] },
    { name: "portrait.mp4", args: ["--duration", "4", "--portrait"] },
    { name: "rotated.mov", args: ["--duration", "4", "--rotation"] },
    { name: "silent.mp4", args: ["--duration", "4", "--silent"] },
  ];
  for (const fixture of fixtures) {
    const output = path.join(generated, fixture.name);
    if (!fs.existsSync(output)) {
      execFileSync(process.env.BJJ_E2E_PYTHON ?? "python", [
        generator,
        output,
        ...fixture.args,
      ]);
    }
  }
  // Chromium reads this as a real capture device; MediaRecorder and upload remain unmodified.
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-y",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=880:sample_rate=48000:duration=30",
    "-af",
    "volume=3",
    "-ac",
    "1",
    "-c:a",
    "pcm_s16le",
    path.join(generated, "microphone-880hz.wav"),
  ]);
}
