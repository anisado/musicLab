#!/bin/bash
# Wrap build/MusicLab.app in a distributable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh

rm -f build/MusicLab.dmg
hdiutil create -volname MusicLab -srcfolder build/MusicLab.app -ov -format UDZO build/MusicLab.dmg

echo "build/MusicLab.dmg"
