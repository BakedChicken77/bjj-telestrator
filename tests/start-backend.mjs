import { spawn } from "node:child_process";

// Argument arrays preserve Windows interpreter paths containing spaces.
const child = spawn(
  process.env.BJJ_E2E_PYTHON ?? "python",
  [
    "-m",
    "uvicorn",
    "app.main:app",
    "--app-dir",
    "backend",
    "--host",
    "127.0.0.1",
    "--port",
    process.env.BJJ_E2E_API_PORT ?? "8010",
  ],
  { stdio: "inherit", env: process.env },
);

child.on("error", (error) => {
  console.error(`Could not start the E2E backend: ${error.message}`);
  process.exitCode = 1;
});
child.on("exit", (code) => {
  process.exitCode = code ?? 1;
});
process.on("SIGTERM", () => child.kill("SIGTERM"));
process.on("SIGINT", () => child.kill("SIGINT"));
