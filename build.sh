#!/bin/bash
# Builds AirPodsKeybind.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AirPodsKeybind.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1s of silence, looped, to hold the audio session that backs the Now Playing slot
python3 - <<'PY'
import wave
with wave.open('build/AirPodsKeybind.app/Contents/Resources/silence.wav', 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b'\x00\x00' * 44100)
PY

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AirPodsKeybind</string>
  <key>CFBundleExecutable</key><string>AirPodsKeybind</string>
  <key>CFBundleIdentifier</key><string>local.airpods-keybind</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

swiftc -O main.swift -o "$APP/Contents/MacOS/AirPodsKeybind" \
  -framework Cocoa -framework AVFoundation -framework MediaPlayer

# Ad-hoc sign so the Accessibility grant sticks to a stable identity across rebuilds.
codesign --force --sign - "$APP"

echo "built: $APP"
