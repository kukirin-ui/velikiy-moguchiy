#!/bin/zsh
# Runs the unit tests once on an iPhone simulator. No retry loop on purpose:
# a crash makes macOS pop up a crash dialog for every attempt.
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate >/dev/null
xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
