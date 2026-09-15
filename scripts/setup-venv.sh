#!/bin/bash
# Dev helper: create a venv with demucs so the app can separate stems with the
# Mac's GPU (mps). The app looks for helper/venv/bin/demucs relative to the
# working directory, or at ~/Library/Application Support/MusicLab/venv.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3.11}"
if ! command -v "$PYTHON" >/dev/null; then
  echo "python3.11 not found — install it with: brew install python@3.11" >&2
  exit 1
fi

"$PYTHON" -m venv helper/venv
helper/venv/bin/pip install --upgrade pip
helper/venv/bin/pip install torch==2.4.1 torchaudio==2.4.1 demucs==4.0.1 mutagen

echo "done — demucs runs on device: mps (override with DEMUCS_DEVICE)"
