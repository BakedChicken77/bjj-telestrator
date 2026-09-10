"""Run required quality gates. Invoke with the backend virtualenv's Python."""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from generate_test_video import generate

ROOT = Path(__file__).resolve().parents[1]


def run(arguments: list[str], cwd: Path, environment: dict[str, str]) -> None:
    print(f"\n{cwd.name}: {' '.join(arguments)}", flush=True)
    subprocess.run(arguments, cwd=cwd, env=environment, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", action="store_true", help="Also run real Playwright exports")
    options = parser.parse_args()
    environment = dict(os.environ)
    environment["BJJ_E2E_PYTHON"] = sys.executable
    npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
    if not npm:
        raise SystemExit("Node.js/npm is not on PATH")
    run([sys.executable, "-m", "pytest", "-q"], ROOT / "backend", environment)
    run([sys.executable, "-m", "ruff", "check", "."], ROOT / "backend", environment)
    run([sys.executable, "-m", "ruff", "check", "--config", "backend/pyproject.toml", "scripts"], ROOT, environment)
    run([sys.executable, "-m", "unittest", "discover", "-s", "tests/repository", "-v"], ROOT, environment)
    for task in ("test", "lint", "typecheck", "build", "format:check"):
        run([npm, "run", task], ROOT / "frontend", environment)
    if options.browser:
        fixtures = ROOT / "tests" / "generated"
        generate(fixtures / "acceptance.mp4")
        generate(fixtures / "portrait.mp4", 4, portrait=True)
        generate(fixtures / "rotated.mov", 4, rotation=True)
        generate(fixtures / "silent.mp4", 4, audio=False)
        run([npm, "run", "test:e2e"], ROOT / "frontend", environment)
    print("\nAll requested verification gates passed.")


if __name__ == "__main__":
    main()
