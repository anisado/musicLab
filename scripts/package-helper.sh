#!/bin/bash
# Package demucs as a standalone helper binary via PyInstaller, so the shipped
# .app can separate stems without a Python install. Output: helper/dist/stems-tool
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="helper/venv"
if [ ! -x "$VENV/bin/python" ]; then
  echo "no venv — run scripts/setup-venv.sh first" >&2
  exit 1
fi

"$VENV/bin/pip" install pyinstaller mutagen
"$VENV/bin/pyinstaller" --onefile --name stems-tool \
  --hidden-import demucs.separate \
  --hidden-import torchaudio \
  --hidden-import mutagen \
  --add-data "$VENV/lib/python3.11/site-packages/demucs/remote:demucs/remote" \
  helper/stems_tool.py \
  --distpath helper/dist --workpath helper/build --specpath helper

echo "helper/dist/stems-tool — bundle.sh copies it into MusicLab.app"
