import playwright from "../../frontend/node_modules/@playwright/test/index.js";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { projectSchema } from "../../frontend/src/model";

const { test, expect } = playwright;
const fixture = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../generated/silent.mp4",
);

// This browser must honor denial, so it deliberately omits automatic fake-UI approval.
test.use({
  launchOptions: {
    executablePath: process.env.BJJ_E2E_CHROMIUM_PATH,
    args: [
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--use-fake-device-for-media-stream",
    ],
  },
});

test("denied microphone permission shows a useful error and unlocks the editor", async ({
  page,
  context,
}) => {
  await page.goto("/");
  const upload = page.getByLabel("Import video", { exact: true });
  await expect(upload).toBeEnabled();
  const imported = page.waitForResponse(
    (response) =>
      response.url().endsWith("/api/projects/import") &&
      response.request().method() === "POST",
  );
  await upload.setInputFiles(fixture);
  const response = await imported;
  expect(response.ok()).toBeTruthy();
  const project = projectSchema.parse(await response.json());
  await expect(page.locator("video")).toBeVisible();
  const session = await context.newCDPSession(page);
  const { targetInfo } = await session.send("Target.getTargetInfo");
  await session.send("Browser.setPermission", {
    permission: { name: "microphone" },
    setting: "denied",
    origin: new URL(page.url()).origin,
    browserContextId: targetInfo.browserContextId,
  });
  expect(
    await page.evaluate(
      async () =>
        (await navigator.permissions.query({ name: "microphone" })).state,
    ),
  ).toBe("denied");
  await page
    .getByRole("button", { name: "Record voiceover", exact: true })
    .click();
  await expect(page.getByRole("alert")).toContainText(
    "Microphone permission was denied",
  );
  await expect(page.getByLabel("Seek video", { exact: true })).toBeEnabled();
  await expect(
    page.getByRole("button", { name: "Record voiceover", exact: true }),
  ).toBeEnabled();
  const saved = await page.request.get(`/api/projects/${project.projectId}`);
  expect(projectSchema.parse(await saved.json()).voiceovers).toHaveLength(0);
});
