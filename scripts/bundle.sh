#!/bin/bash
# Build a release binary and wrap it in MusicLab.app — no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MusicLab.app"
IDENTIFIER="dev.personal.musiclab"
VERSION="0.1.0"

# SwiftUI needs the full Xcode toolchain (SwiftUIMacros plugin), not just the CLT
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$xcode" ]; then
      export DEVELOPER_DIR="$xcode/Contents/Developer"
      break
    fi
  done
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/MusicLab" "$APP/Contents/MacOS/MusicLab"

# ship the demucs helper when it has been packaged (scripts/package-helper.sh)
if [ -f helper/dist/stems-tool ]; then
  cp helper/dist/stems-tool "$APP/Contents/Resources/stems-tool"
  chmod +x "$APP/Contents/Resources/stems-tool"
fi

# the tagging helper script runs under any python with mutagen installed
cp helper/stems_tool.py "$APP/Contents/Resources/stems_tool.py"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MusicLab</string>
    <key>CFBundleIdentifier</key><string>${IDENTIFIER}</string>
    <key>CFBundleName</key><string>MusicLab</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>MusicLab only plays local audio files.</string>
</dict>
</plist>
EOF

# ad-hoc sign so Gatekeeper lets it launch locally; use a Developer ID to share
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "$APP"
