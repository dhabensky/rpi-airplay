#!/bin/bash
# One-time/idempotent venv bootstrap for tools/pytest/ -- Homebrew's system
# Python is externally-managed (PEP 668), so a project-local venv is
# required, not optional. Safe to re-run: only reinstalls if
# requirements.txt changed since the venv was last built.
set -euo pipefail
cd "$(dirname "$0")/pytest"

VENV=.venv
STAMP="$VENV/.requirements.stamp"

if [ ! -x "$VENV/bin/pytest" ] || [ requirements.txt -nt "$STAMP" ]; then
  echo "==> Building venv"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r requirements.txt
  touch "$STAMP"
else
  echo "==> venv already up to date"
fi

echo "==> $("$VENV/bin/pytest" --version)"
echo "Run tests with: tools/pytest/.venv/bin/pytest tools/pytest/ [-v] [-m \"not pi_hardware\"]"
