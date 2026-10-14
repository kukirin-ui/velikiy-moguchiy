#!/bin/bash
# Сборка «Конвейер.app» в ~/Applications обычным swiftc. Запуск: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Конвейер.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/Conveyor" main.swift
cp status.py "$APP/Contents/Resources/status.py"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.velikiy-moguchiy.pipeline-status</string>
<key>CFBundleName</key><string>Конвейер</string>
<key>CFBundleDisplayName</key><string>Конвейер</string>
<key>CFBundleExecutable</key><string>Conveyor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "собрано: $APP"
