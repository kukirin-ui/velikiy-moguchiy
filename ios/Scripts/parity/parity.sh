#!/bin/zsh
# Keyboard parity gate. Renders Apple's system keyboard and Великий & Могучий RU/EN over
# the same plain UIKit text field (KeyboardParityHost) in the same simulator (iPhone 16, 393 pt),
# for each field type, light and dark, and compares them with
# compare.py. Exits non-zero when any layout is more than 1 pt off.
#
# Headless: simctl and XCUITest only, Simulator.app is never opened.
# Apple's screenshots are kept in Tests/Reference/Apple/simulator/<runtime>/
# and recaptured when the runtime changes or REFRESH_APPLE=1.
# Report: build/parity/report/report.html
set -euo pipefail
cd "${0:A:h:h:h}"
ROOT=$PWD
OUT=$ROOT/build/parity
DERIVED=$OUT/derived
DEVICE_NAME="VelikiyMoguchiy Parity iPhone 16"
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-16
CASES="text:return:1,url:return:1,web:go:1,web:go:0,email:return:1,number:return:1"
# While iterating on one layout, PARITY_CASES / PARITY_APPEARANCES narrow the
# run. build-ipa.sh clears both, so the gate always checks everything.
CASES=${PARITY_CASES:-$CASES}
APPEARANCES=${PARITY_APPEARANCES:-dark light}
APPLE_RU="ru_RU@sw=Russian;hw=Automatic"
APPLE_EN="en_US@sw=QWERTY;hw=Automatic"
source Scripts/xcconfig.zsh
require_renamed_secrets
# Our keyboards as the Debug build identifies them (Config/Secrets.xcconfig or the public defaults).
OURS_RU=$(xcconfig_setting Debug VELIKIY_MOGUCHIY_KEYBOARD_RU_BUNDLE_IDENTIFIER)
OURS_EN=$(xcconfig_setting Debug VELIKIY_MOGUCHIY_KEYBOARD_EN_BUNDLE_IDENTIFIER)

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["platform"] == "iOS"]
print(sorted(rs, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"])')
RUNTIME_NAME=${RUNTIME##*.}
UDID=$(xcrun simctl list devices -j | python3 -c "
import json, sys
for runtime, devices in json.load(sys.stdin)['devices'].items():
    if runtime == '$RUNTIME':
        for d in devices:
            if d['name'] == '$DEVICE_NAME' and d['isAvailable']: print(d['udid'])" | head -1)
[[ -n "$UDID" ]] || UDID=$(xcrun simctl create "$DEVICE_NAME" $DEVICE_TYPE $RUNTIME)
REFERENCE=$ROOT/Tests/Reference/Apple/simulator/iPhone16-$RUNTIME_NAME
echo "parity: $DEVICE_NAME ($UDID), $RUNTIME_NAME"

mkdir -p $OUT
xcodegen generate >/dev/null
xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme KeyboardParity -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath $DERIVED \
  CODE_SIGNING_ALLOWED=NO build-for-testing > $OUT/build.log 2>&1 \
  || { tail -20 $OUT/build.log; echo "parity: build failed"; exit 1; }
XCTESTRUN=$(ls $DERIVED/Build/Products/*.xctestrun | head -1)

boot() {
  xcrun simctl boot $UDID 2>/dev/null || true
  xcrun simctl bootstatus $UDID -b >/dev/null
}

# keyboards <active id> <other ids...>: iOS reads the list and the last used
# keyboard at boot, so the simulator restarts.
keyboards() {
  boot
  xcrun simctl spawn $UDID defaults write .GlobalPreferences AppleKeyboards -array "$@"
  xcrun simctl spawn $UDID defaults write .GlobalPreferences AppleKeyboardsExpanded -int 1
  xcrun simctl shutdown $UDID
  python3 - "$1" ~/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences/com.apple.keyboard.preferences.plist <<'PY'
import os, plistlib, sys
active, path = sys.argv[1], sys.argv[2]
d = plistlib.load(open(path, "rb")) if os.path.exists(path) else {}
d["KeyboardLastUsed"] = active
for k in ("KeyboardDidShowGestureKeyboardIntroduction", "DidShowGestureKeyboardIntroduction",
          "KeyboardDidShowSlideToTypeIntroduction", "DidShowContinuousPathIntroduction"):
    d[k] = True
d["KeyboardLastUsedForLanguage"] = {k: active for k in ("ASCIICapable", "en_US", "NonASCII", "ru_RU")}
plistlib.dump(d, open(path, "wb"))
PY
  boot
}

# capture <prefix> <dir>: every case in light and dark with the active keyboard.
capture() {
  mkdir -p $2
  for appearance in ${=APPEARANCES}; do
    xcrun simctl ui $UDID appearance $appearance
    sleep 2
    env TEST_RUNNER_PARITY_OUT=$2 TEST_RUNNER_PARITY_PREFIX=$1-$appearance \
      TEST_RUNNER_PARITY_KINDS=$CASES \
      xcodebuild test-without-building -xctestrun $XCTESTRUN -destination "id=$UDID" \
      -only-testing:KeyboardParityUITests/KeyboardParityCaptureTests/testCaptureKeyboards \
      > $OUT/capture-$1-$appearance.log 2>&1 \
      || { tail -20 $OUT/capture-$1-$appearance.log; echo "parity: capture $1 failed"; exit 1; }
  done
  # Only the keyboard and a little above it are compared (and kept in git).
  python3 - $2/$1-*.png <<'PY'
import sys
from PIL import Image
for path in sys.argv[1:]:
    image = Image.open(path)
    image.crop((0, image.height - 1300, image.width, image.height)).save(path, optimize=True)
PY
}

boot
xcrun simctl install $UDID $DERIVED/Build/Products/Debug-iphonesimulator/VelikiyMoguchiy.app
xcrun simctl install $UDID $DERIVED/Build/Products/Debug-iphonesimulator/KeyboardParityHost.app

if [[ ! -d $REFERENCE || "${REFRESH_APPLE:-0}" == 1 ]]; then
  echo "parity: capturing Apple's keyboards"
  rm -rf $REFERENCE
  keyboards "$APPLE_RU" "$APPLE_RU" "$APPLE_EN" emoji $OURS_RU $OURS_EN
  capture apple-ru $REFERENCE
  keyboards "$APPLE_EN" "$APPLE_EN" "$APPLE_RU" emoji $OURS_RU $OURS_EN
  capture apple-en $REFERENCE
fi

rm -rf $OUT/ours
keyboards $OURS_RU $OURS_RU $OURS_EN
capture ours-ru $OUT/ours
keyboards $OURS_EN $OURS_EN $OURS_RU
capture ours-en $OUT/ours
xcrun simctl shutdown $UDID

python3 Scripts/parity/compare.py --reference $REFERENCE --ours $OUT/ours \
  --device $ROOT/Tests/Reference/Apple/device --out $OUT/report
