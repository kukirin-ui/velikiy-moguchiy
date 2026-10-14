#!/bin/zsh
# Rebuild, reinstall into the booted simulator and relaunch the app.
set -e
cd "${0:A:h:h}"
source Scripts/xcconfig.zsh
require_renamed_secrets
APP_ID=$(xcconfig_setting Debug VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER)
xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD" || true
APP=$(find DerivedData/Build/Products -name VelikiyMoguchiy.app -path '*iphonesimulator*' | head -1)
xcrun simctl terminate booted "$APP_ID" 2>/dev/null || true
xcrun simctl install booted "$APP"
SIMCTL_CHILD_VELIKIY_MOGUCHIY_TRYOUT=${TRYOUT:-0} xcrun simctl launch booted "$APP_ID"
