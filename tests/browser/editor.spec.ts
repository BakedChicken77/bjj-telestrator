import playwright, {
  type Page,
} from "../../frontend/node_modules/@playwright/test/index.js";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { projectSchema, type Project } from "../../frontend/src/model";

const { test, expect } = playwright;

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const fixtures = path.join(root, "tests/generated");

async function importVideo(page: Page, filename: string): Promise<Project> {
  await page.goto("/");
  const upload = page.getByLabel("Import video", { exact: true });
  await expect(upload).toBeAttached();
  await expect(upload).toBeEnabled();
  const imported = page.waitForResponse(
    (response) =>
      response.url().endsWith("/api/projects/import") &&
      response.request().method() === "POST",
    { timeout: 90_000 },
  );
  await upload.setInputFiles(path.join(fixtures, filename));
  const response = await imported;
  expect(response.ok(), await response.text()).toBeTruthy();
  const project = projectSchema.parse(await response.json());
  await expect(page.locator("video")).toBeVisible();
  await expect
    .poll(() =>
      page
        .locator("video")
        .evaluate((video: HTMLVideoElement) => video.readyState),
    )
    .toBeGreaterThanOrEqual(2);
  return project;
}

async function savedProject(page: Page, id: string): Promise<Project> {
  const response = await page.request.get(`/api/projects/${id}`);
  expect(response.ok()).toBeTruthy();
  return projectSchema.parse(await response.json());
}

async function seek(page: Page, seconds: number): Promise<void> {
  // Exercise the range control's normal input/change handlers at an exact media timestamp.
  await page
    .getByLabel("Seek video", { exact: true })
    .evaluate((element, value) => {
      const setter = Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )?.set;
      setter?.call(element, String(value));
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    }, seconds);
  await expect
    .poll(() =>
      page
        .locator("video")
        .evaluate((video: HTMLVideoElement) => video.currentTime),
    )
    .toBeCloseTo(seconds, 2);
  await expect
    .poll(() =>
      page
        .locator("video")
        .evaluate((video: HTMLVideoElement) => video.seeking),
    )
    .toBe(false);
}

async function draw(
  page: Page,
  tool: string,
  from: [number, number],
  to: [number, number],
): Promise<void> {
  await page.getByRole("button", { name: tool, exact: true }).click();
  await dragPicture(page, from, to);
}

async function dragPicture(
  page: Page,
  from: [number, number],
  to: [number, number],
): Promise<void> {
  const rectangle = await page.getByTestId("video-picture").boundingBox();
  if (!rectangle) throw new Error("The video picture is not visible");
  await page.mouse.move(
    rectangle.x + from[0] * rectangle.width,
    rectangle.y + from[1] * rectangle.height,
  );
  await page.mouse.down();
  await page.mouse.move(
    rectangle.x + to[0] * rectangle.width,
    rectangle.y + to[1] * rectangle.height,
    { steps: 14 },
  );
  await page.mouse.up();
}

async function field(page: Page, label: string, value: string): Promise<void> {
  const input = page.getByLabel(label, { exact: true });
  if ((await input.getAttribute("type")) === "color") {
    if ((await input.inputValue()) === value) return;
    await input.evaluate((element, color) => {
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )?.set?.call(element, color);
      element.dispatchEvent(new Event("input", { bubbles: true }));
      element.dispatchEvent(new Event("change", { bubbles: true }));
    }, value);
    await page
      .getByRole("button", {
        name: `Apply ${label.toLowerCase()}`,
        exact: true,
      })
      .click();
    return;
  }
  await input.fill(value);
  await input.press("Tab");
}

async function visibleAnnotations(page: Page, ids: string[]): Promise<void> {
  await expect
    .poll(async () => {
      const value = await page
        .getByTestId("video-stage")
        .getAttribute("data-visible-annotation-ids");
      return (
        value?.startsWith("[")
          ? (JSON.parse(value) as string[])
          : (value?.split(",").filter(Boolean) ?? [])
      ).sort();
    })
    .toEqual([...ids].sort());
}

interface ProbeStream {
  codec_type: string;
  codec_name: string;
  width?: number;
  height?: number;
}
interface ProbeResult {
  streams: ProbeStream[];
  format: { format_name: string; duration: string };
}

function probe(file: string): ProbeResult {
  return JSON.parse(
    execFileSync(
      "ffprobe",
      ["-v", "error", "-show_streams", "-show_format", "-of", "json", file],
      { encoding: "utf8" },
    ),
  ) as ProbeResult;
}

function colorsAt(
  file: string,
  seconds: number,
): { red: number; yellow: number } {
  const pixels = execFileSync(
    "ffmpeg",
    [
      "-v",
      "error",
      "-ss",
      String(seconds),
      "-i",
      file,
      "-frames:v",
      "1",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "pipe:1",
    ],
    { maxBuffer: 10 * 1024 * 1024 },
  );
  let red = 0;
  let yellow = 0;
  for (let i = 0; i < pixels.length; i += 3) {
    if (pixels[i] > 180 && pixels[i + 1] < 100 && pixels[i + 2] < 100) red++;
    if (pixels[i] > 180 && pixels[i + 1] > 160 && pixels[i + 2] < 100) yellow++;
  }
  return { red, yellow };
}

async function exportVideo(page: Page, output: string): Promise<void> {
  await page.getByRole("button", { name: "Export video", exact: true }).click();
  await page.getByRole("button", { name: "Render MP4", exact: true }).click();
  const downloadLink = page
    .getByRole("link", { name: /Download MP4/i })
    .first();
  await expect(downloadLink).toBeVisible({ timeout: 120_000 });
  const downloadEvent = page.waitForEvent("download");
  await downloadLink.click();
  const download = await downloadEvent;
  expect(download.suggestedFilename()).toMatch(/-annotated-.*\.mp4$/);
  await download.saveAs(output);
  expect(await download.failure()).toBeNull();
}

test("20-second coaching review persists edits and exports frame-accurate burned annotations", async ({
  page,
}, testInfo) => {
  const source = path.join(fixtures, "acceptance.mp4");
  const originalHash = createHash("sha256")
    .update(fs.readFileSync(source))
    .digest("hex");
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const project = await importVideo(page, "acceptance.mp4");

  await seek(page, 5);
  await draw(page, "Arrow", [0.2, 0.5], [0.62, 0.5]);
  await field(page, "Stroke color", "#ff0000");
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.length,
    )
    .toBe(1);
  let saved = await savedProject(page, project.projectId);
  const arrow = saved.annotations[0];
  expect(arrow.type).toBe("arrow");
  expect(arrow.startSec).toBeCloseTo(5, 3);
  expect(arrow.endSec).toBeCloseTo(10, 3);

  await seek(page, 7);
  await draw(page, "Ellipse", [0.56, 0.25], [0.83, 0.75]);
  await field(page, "Stroke color", "#ffff00");
  await field(page, "End time", "00:09.000");
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.find(
          (a) => a.type === "ellipse",
        )?.endSec,
    )
    .toBe(9);
  saved = await savedProject(page, project.projectId);
  const circle = saved.annotations.find(
    (annotation) => annotation.type === "ellipse",
  );
  if (!circle) throw new Error("Ellipse was not persisted");

  for (const [time, visible] of [
    [4.9, []],
    [5, [arrow.id]],
    [7.5, [arrow.id, circle.id]],
    [9.5, [arrow.id]],
    [10, []],
  ] as [number, string[]][]) {
    await seek(page, time);
    await visibleAnnotations(page, visible);
  }

  await seek(page, 7.5);
  await page.getByTestId(`timeline-annotation-${arrow.id}`).click();
  await dragPicture(page, [0.4, 0.5], [0.4, 0.58]);
  await expect
    .poll(async () => {
      const item = (
        await savedProject(page, project.projectId)
      ).annotations.find((a) => a.id === arrow.id);
      return item?.type === "arrow" ? item.geometry.y1 : 0;
    })
    .toBeCloseTo(0.58, 2);
  await dragPicture(page, [0.62, 0.58], [0.72, 0.64]);
  await expect
    .poll(async () => {
      const item = (
        await savedProject(page, project.projectId)
      ).annotations.find((a) => a.id === arrow.id);
      return item?.type === "arrow" ? item.geometry.x2 : 0;
    })
    .toBeCloseTo(0.72, 2);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect
    .poll(async () => {
      const item = (
        await savedProject(page, project.projectId)
      ).annotations.find((a) => a.id === arrow.id);
      return item?.type === "arrow" ? item.geometry.x2 : 0;
    })
    .toBeCloseTo(0.62, 2);
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect
    .poll(async () => {
      const item = (
        await savedProject(page, project.projectId)
      ).annotations.find((a) => a.id === arrow.id);
      return item?.type === "arrow" ? item.geometry.x2 : 0;
    })
    .toBeCloseTo(0.72, 2);

  await page.getByTestId(`timeline-annotation-${circle.id}`).click();
  await field(page, "End time", "00:09.250");
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(page.getByLabel("End time", { exact: true })).toHaveValue(
    "00:09.000",
  );
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect(page.getByLabel("End time", { exact: true })).toHaveValue(
    "00:09.250",
  );
  await field(page, "End time", "00:09.000");

  await expect(page.getByTestId("save-status")).toHaveText("Saved");
  await page.reload();
  await expect(page.locator("video")).toBeVisible();
  await expect(
    page.getByTestId(`timeline-annotation-${arrow.id}`),
  ).toBeVisible();
  await expect(
    page.getByTestId(`timeline-annotation-${circle.id}`),
  ).toBeVisible();
  await seek(page, 7.5);
  await visibleAnnotations(page, [arrow.id, circle.id]);
  await page.getByTestId(`timeline-annotation-${arrow.id}`).click();
  await page.screenshot({
    path: path.join(fixtures, "editor-screenshot.png"),
    fullPage: true,
  });
  await testInfo.attach("Editor with timed coaching annotations", {
    path: path.join(fixtures, "editor-screenshot.png"),
    contentType: "image/png",
  });

  const output = testInfo.outputPath("review-annotated.mp4");
  await exportVideo(page, output);
  const metadata = probe(output);
  expect(metadata.format.format_name).toContain("mp4");
  expect(
    metadata.streams.find((stream) => stream.codec_type === "video"),
  ).toMatchObject({ codec_name: "h264", width: 640, height: 360 });
  expect(
    metadata.streams.find((stream) => stream.codec_type === "audio"),
  ).toMatchObject({ codec_name: "aac" });
  expect(Math.abs(Number(metadata.format.duration) - 20)).toBeLessThanOrEqual(
    0.1,
  );
  expect(colorsAt(output, 4.9)).toEqual({ red: 0, yellow: 0 });
  expect(colorsAt(output, 5).red).toBeGreaterThan(100);
  expect(colorsAt(output, 7.5).red).toBeGreaterThan(100);
  expect(colorsAt(output, 7.5).yellow).toBeGreaterThan(100);
  expect(colorsAt(output, 9.5).yellow).toBe(0);
  expect(colorsAt(output, 9.5).red).toBeGreaterThan(100);
  expect(colorsAt(output, 10)).toEqual({ red: 0, yellow: 0 });
  expect(
    createHash("sha256").update(fs.readFileSync(source)).digest("hex"),
  ).toBe(originalHash);
  expect(errors).toEqual([]);
  fs.mkdirSync(path.join(root, "docs"), { recursive: true });
  fs.copyFileSync(output, path.join(root, "docs/sample-annotated.mp4"));
});

test("all drawing tools and grouped timeline drag/trim work at 1280 by 720", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1280, height: 720 });
  const project = await importVideo(page, "silent.mp4");
  await seek(page, 0.5);
  for (const [tool, from, to] of [
    ["Line", [0.12, 0.15], [0.65, 0.2]],
    ["Rectangle", [0.2, 0.3], [0.5, 0.6]],
    ["Freehand", [0.6, 0.3], [0.8, 0.7]],
    ["Text", [0.12, 0.7], [0.12, 0.7]],
  ] as [string, [number, number], [number, number]][]) {
    await draw(page, tool, from, to);
  }
  await field(page, "Text content", "Keep your elbow connected");
  await field(page, "Text size (px)", "18");
  await field(page, "End time", "00:02.500");
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.length,
    )
    .toBe(4);
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.find(
          (a) => a.type === "text",
        )?.endSec,
    )
    .toBe(2.5);
  const saved = await savedProject(page, project.projectId);
  expect(saved.annotations.map((a) => a.type).sort()).toEqual([
    "freehand",
    "line",
    "rectangle",
    "text",
  ]);
  const text = saved.annotations.find((a) => a.type === "text");
  if (!text || text.type !== "text")
    throw new Error("Text tool did not persist a text annotation");
  expect(text.geometry.text).toBe("Keep your elbow connected");
  expect(text.geometry.fontSize).toBeCloseTo(18 / 360, 5);
  const freehand = saved.annotations.find((a) => a.type === "freehand");
  expect(
    freehand?.type === "freehand" ? freehand.geometry.points.length : 0,
  ).toBeGreaterThan(2);

  const bar = page.getByTestId(`timeline-annotation-${text.id}`);
  await bar.scrollIntoViewIfNeeded();
  const barBox = await bar.boundingBox();
  const fullBarBox = await bar.locator("..").boundingBox();
  if (!barBox || !fullBarBox)
    throw new Error("Timeline annotation is not visible");
  const pixelsPerSecond = fullBarBox.width / 2;
  await page.mouse.move(
    barBox.x + barBox.width / 2,
    barBox.y + barBox.height / 2,
  );
  await page.mouse.down();
  await page.mouse.move(
    barBox.x + barBox.width / 2 + pixelsPerSecond * 0.5,
    barBox.y + barBox.height / 2,
    { steps: 12 },
  );
  await page.mouse.up();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.find(
          (a) => a.id === text.id,
        )?.startSec,
    )
    .toBeCloseTo(1, 2);

  const edge = await page
    .getByRole("button", { name: "Trim text end", exact: true })
    .boundingBox();
  if (!edge) throw new Error("Timeline trim handle is not visible");
  await page.mouse.move(edge.x + edge.width / 2, edge.y + edge.height / 2);
  await page.mouse.down();
  await page.mouse.move(
    edge.x + edge.width / 2 - pixelsPerSecond * 0.25,
    edge.y + edge.height / 2,
    { steps: 12 },
  );
  await page.mouse.up();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).annotations.find(
          (a) => a.id === text.id,
        )?.endSec,
    )
    .toBeCloseTo(2.75, 2);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(page.getByLabel("End time", { exact: true })).toHaveValue(
    "00:03.000",
  );
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(page.getByLabel("Start time", { exact: true })).toHaveValue(
    "00:00.500",
  );
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect(page.getByLabel("End time", { exact: true })).toHaveValue(
    "00:02.750",
  );

  await page
    .getByRole("button", { name: "Delete selected annotation", exact: true })
    .click();
  await expect(bar).not.toBeAttached();
  await page.keyboard.press("Control+z");
  await expect(bar).toBeAttached();
  await seek(page, 1.5);
  await page.screenshot({
    path: path.join(fixtures, "editor-1280x720.png"),
    fullPage: true,
  });
  await testInfo.attach("Minimum desktop resolution", {
    path: path.join(fixtures, "editor-1280x720.png"),
    contentType: "image/png",
  });
});

for (const variant of [
  { file: "portrait.mp4", width: 360, height: 640, audio: true },
  { file: "rotated.mov", width: 360, height: 640, audio: true },
  { file: "silent.mp4", width: 640, height: 360, audio: false },
]) {
  test(`${variant.file} imports, aligns the drawing surface, and exports in display orientation`, async ({
    page,
  }, testInfo) => {
    const project = await importVideo(page, variant.file);
    expect(project.source.displayWidth).toBe(variant.width);
    expect(project.source.displayHeight).toBe(variant.height);
    expect(project.proxy.codec).toBe("h264");
    await seek(page, 1);
    const rectangle = await page.getByTestId("video-picture").boundingBox();
    expect(rectangle).not.toBeNull();
    expect(rectangle!.width / rectangle!.height).toBeCloseTo(
      variant.width / variant.height,
      2,
    );
    await draw(page, "Rectangle", [0.2, 0.2], [0.7, 0.6]);
    await field(page, "Stroke color", "#ff0000");
    await expect
      .poll(
        async () =>
          (await savedProject(page, project.projectId)).annotations.length,
      )
      .toBe(1);
    const output = testInfo.outputPath("variant-annotated.mp4");
    await exportVideo(page, output);
    const metadata = probe(output);
    expect(
      metadata.streams.find((stream) => stream.codec_type === "video"),
    ).toMatchObject({
      codec_name: "h264",
      width: variant.width,
      height: variant.height,
    });
    expect(
      metadata.streams.some((stream) => stream.codec_type === "audio"),
    ).toBe(variant.audio);
    expect(colorsAt(output, 0.5).red).toBe(0);
    expect(colorsAt(output, 1.5).red).toBeGreaterThan(100);
  });
}

interface AudioStartObservation {
  when: number;
  offset: number;
  contextTime: number;
  mediaTime: number;
}
interface AudioObservations {
  starts: AudioStartObservation[];
  stops: number;
}

function toneAmplitude(
  file: string,
  startSec: number,
  frequency: number,
): number {
  const rate = 48_000;
  const audio = execFileSync(
    "ffmpeg",
    [
      "-v",
      "error",
      "-ss",
      String(startSec),
      "-i",
      file,
      "-t",
      "0.3",
      "-vn",
      "-ac",
      "1",
      "-ar",
      String(rate),
      "-f",
      "f32le",
      "pipe:1",
    ],
    { maxBuffer: 1024 * 1024 },
  );
  let cosine = 0;
  let sine = 0;
  const count = audio.length / 4;
  for (let index = 0; index < count; index++) {
    const sample = audio.readFloatLE(index * 4);
    const angle = (2 * Math.PI * frequency * index) / rate;
    cosine += sample * Math.cos(angle);
    sine += sample * Math.sin(angle);
  }
  return (2 * Math.hypot(cosine, sine)) / count;
}

async function recordClip(
  page: Page,
  projectId: string,
  atSec: number,
  count: number,
): Promise<void> {
  await seek(page, atSec);
  await page
    .getByRole("button", { name: "Record voiceover", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Stop recording", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Seek video", { exact: true })).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Pause video", exact: true }),
  ).toBeDisabled();
  await expect
    .poll(() =>
      page
        .locator("video")
        .evaluate((video: HTMLVideoElement) => video.currentTime),
    )
    .toBeGreaterThan(atSec + 1.3);
  await page
    .getByRole("button", { name: "Stop recording", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Record voiceover", exact: true }),
  ).toBeEnabled();
  await expect
    .poll(async () => (await savedProject(page, projectId)).voiceovers.length)
    .toBe(count);
  await expect(page.getByLabel("Seek video", { exact: true })).toBeEnabled();
}

test("real microphone clips persist, preview in sync, rerecord, and mix into AAC at their timeline times", async ({
  page,
  context,
}, testInfo) => {
  await context.grantPermissions(["microphone"]);
  await page.addInitScript(() => {
    // Observe native Web Audio scheduling without replacing its processing or output.
    const observed = {
      starts: [] as {
        when: number;
        offset: number;
        contextTime: number;
        mediaTime: number;
      }[],
      stops: 0,
    };
    Object.defineProperty(window, "__bjjAudioObservations", {
      value: observed,
    });
    const originalStart = AudioBufferSourceNode.prototype.start;
    const originalStop = AudioBufferSourceNode.prototype.stop;
    AudioBufferSourceNode.prototype.start = function (
      when = 0,
      offset = 0,
      duration?: number,
    ) {
      observed.starts.push({
        when,
        offset,
        contextTime: this.context.currentTime,
        mediaTime: document.querySelector("video")?.currentTime ?? 0,
      });
      if (duration === undefined) originalStart.call(this, when, offset);
      else originalStart.call(this, when, offset, duration);
    };
    AudioBufferSourceNode.prototype.stop = function (when = 0) {
      observed.stops++;
      originalStop.call(this, when);
    };
  });
  const project = await importVideo(page, "acceptance.mp4");
  await recordClip(page, project.projectId, 2, 1);
  await recordClip(page, project.projectId, 8, 2);
  let saved = await savedProject(page, project.projectId);
  expect(Math.abs(saved.voiceovers[0].startSec - 2)).toBeLessThanOrEqual(0.1);
  expect(Math.abs(saved.voiceovers[1].startSec - 8)).toBeLessThanOrEqual(0.1);
  const deletedId = saved.voiceovers[1].id;
  await page
    .getByRole("button", { name: "Delete voiceover 2", exact: true })
    .click();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).voiceovers.length,
    )
    .toBe(1);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).voiceovers[1]?.id,
    )
    .toBe(deletedId);
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).voiceovers.length,
    )
    .toBe(1);
  await recordClip(page, project.projectId, 8, 2);
  saved = await savedProject(page, project.projectId);
  expect(saved.voiceovers[1].id).not.toBe(deletedId);

  await field(page, "Original audio gain", "0.25");
  await page.getByLabel("Mute original audio", { exact: true }).check();
  await field(page, "Voiceover master gain", "1");
  await field(page, "Voiceover 1 gain", "0.8");
  await field(page, "Voiceover 1 timing offset (ms)", "100");
  await field(page, "Voiceover 2 gain", "0.6");
  await field(page, "Voiceover 2 start", "8.1");
  await page.getByLabel("Mute voiceover 2", { exact: true }).check();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).voiceovers[1].muted,
    )
    .toBe(true);
  await page.getByLabel("Mute voiceover 2", { exact: true }).uncheck();
  await expect
    .poll(
      async () =>
        (await savedProject(page, project.projectId)).voiceovers[1].muted,
    )
    .toBe(false);
  await expect(page.getByTestId("save-status")).toHaveText("Saved");
  await page.reload();
  await expect(page.locator("video")).toBeVisible();
  const audioToggle = page.getByRole("button", {
    name: "Audio & voiceovers",
    exact: true,
  });
  if ((await audioToggle.getAttribute("aria-expanded")) === "false")
    await audioToggle.click();
  await expect(
    page.getByLabel("Voiceover 1 timing offset (ms)", { exact: true }),
  ).toHaveValue("100");
  await expect(
    page.getByLabel("Mute original audio", { exact: true }),
  ).toBeChecked();
  saved = await savedProject(page, project.projectId);
  expect(saved.voiceovers).toHaveLength(2);
  expect(saved.settings.originalAudioGain).toBe(0.25);
  expect(saved.voiceovers[0].gain).toBe(0.8);
  expect(saved.voiceovers[1].startSec).toBe(8.1);
  await page
    .getByRole("button", { name: "Close audio controls", exact: true })
    .click();

  await seek(page, 2.5);
  await page.getByRole("button", { name: "Play video", exact: true }).click();
  const observations = () =>
    page.evaluate(
      () =>
        (window as unknown as { __bjjAudioObservations: AudioObservations })
          .__bjjAudioObservations,
    );
  await expect
    .poll(async () => (await observations()).starts.length)
    .toBeGreaterThan(0);
  const observed = await observations();
  const first = observed.starts[0];
  const clipStart =
    saved.voiceovers[0].startSec + saved.voiceovers[0].timingOffsetMs / 1000;
  const expectedOffset =
    first.mediaTime - clipStart + Math.max(0, first.when - first.contextTime);
  expect(Math.abs(first.offset - expectedOffset)).toBeLessThanOrEqual(0.1);
  await page.getByRole("button", { name: "Pause video", exact: true }).click();
  await expect
    .poll(async () => (await observations()).stops)
    .toBeGreaterThan(observed.stops);
  await audioToggle.click();
  await page.screenshot({
    path: path.join(fixtures, "voiceover-editor.png"),
    fullPage: true,
  });
  await testInfo.attach("Recorded voiceover clips", {
    path: path.join(fixtures, "voiceover-editor.png"),
    contentType: "image/png",
  });

  const output = testInfo.outputPath("voiceover-annotated.mp4");
  await exportVideo(page, output);
  const metadata = probe(output);
  expect(
    metadata.streams.find((stream) => stream.codec_type === "audio"),
  ).toMatchObject({ codec_name: "aac" });
  expect(Math.abs(Number(metadata.format.duration) - 20)).toBeLessThanOrEqual(
    0.1,
  );
  expect(toneAmplitude(output, 1, 880)).toBeLessThan(0.001);
  expect(toneAmplitude(output, 2.5, 880)).toBeGreaterThan(0.005);
  expect(toneAmplitude(output, 5, 880)).toBeLessThan(0.001);
  expect(toneAmplitude(output, 8.5, 880)).toBeGreaterThan(0.005);
  expect(toneAmplitude(output, 2.5, 440)).toBeLessThan(0.003);
});
