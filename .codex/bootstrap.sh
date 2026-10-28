#!/usr/bin/env bash
# Reusable dependency/bootstrap step for a Linux Codex Cloud environment.
# Provision Node.js 24, Python 3.12, FFmpeg and FFprobe before invoking.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'Codex bootstrap: %s\n' "$*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || fail "Node.js 24 is required"
command -v npm >/dev/null 2>&1 || fail "npm is required"
node -e 'if (Number(process.versions.node.split(".")[0]) !== 24) process.exit(1)' \
  || fail "Expected Node.js 24 (CI uses 24.19.0); found $(node --version)"
command -v ffmpeg >/dev/null 2>&1 || fail "FFmpeg is missing"
command -v ffprobe >/dev/null 2>&1 || fail "FFprobe is missing"

if command -v python3.12 >/dev/null 2>&1; then
  PYTHON=python3.12
elif command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
else
  fail "Python 3.12 is required"
fi
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else 1)' \
  || fail "Expected Python 3.12 (CI uses 3.12.13)"

if [ ! -x backend/.venv/bin/python ]; then
  "$PYTHON" -m venv backend/.venv
fi
backend/.venv/bin/python -m pip install --disable-pip-version-check -r backend/requirements.txt

(
  cd frontend
  npm ci --no-audit --no-fund
  if [ "${CODEX_INSTALL_BROWSER:-1}" = "1" ]; then
    npx --no-install playwright install chromium
  fi
)

printf '\nCodex bootstrap complete.\n'
printf 'Run checks: backend/.venv/bin/python scripts/verify.py\n'
printf 'Browser checks: backend/.venv/bin/python scripts/verify.py --browser\n'
printf 'Native iOS tests must run on macOS/Xcode through GitHub Actions.\n'
