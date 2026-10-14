#!/usr/bin/env bash
# Runs the instrumented tests (app/src/androidTest) on the one running emulator or device.
#
#   android/scripts/emulator-tests.sh
#
# Installs the debug APK, makes the keyboard the current input method through adb, then runs
# connectedDebugAndroidTest. Logcat, failure screenshots and a final screenshot go to
# android/build/emulator/.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=build/emulator
PACKAGE=io.github.zigansh1n.velikiymoguchiy.debug
IME="$PACKAGE/io.github.zigansh1n.velikiymoguchiy.ime.KeyboardService"
SCREENSHOTS=/data/local/tmp/vm-screenshots

rm -rf "$OUT"
mkdir -p "$OUT"
adb wait-for-device
# A cold boot with software rendering often leaves "Pixel Launcher isn't responding" on screen.
adb shell settings put global hide_error_dialogs 1
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null || true
adb shell input keyevent KEYCODE_WAKEUP
adb shell input keyevent KEYCODE_MENU
adb shell rm -rf "$SCREENSHOTS"
adb logcat -c || true
adb logcat -v threadtime > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!
trap 'kill "$LOGCAT_PID" 2>/dev/null || true' EXIT

./gradlew --console=plain assembleDebug

adb install -r -g app/build/outputs/apk/debug/app-debug.apk
# The input method service sees a new package a moment after the install returns.
for _ in $(seq 60); do
  adb shell ime list -a -s | tr -d '\r' | grep -qxF "$IME" && break
  sleep 1
done
adb shell ime enable "$IME"
adb shell ime set "$IME"
adb shell settings put secure show_ime_with_hard_keyboard 1
ENABLED=$(adb shell ime list -s | tr -d '\r')
if ! grep -qxF "$IME" <<< "$ENABLED"; then
  echo "The keyboard is not among the enabled input methods:" >&2
  echo "$ENABLED" >&2
  exit 1
fi
CURRENT=$(adb shell settings get secure default_input_method | tr -d '\r')
if [ "$CURRENT" != "$IME" ]; then
  echo "Current input method is $CURRENT, expected $IME" >&2
  exit 1
fi
echo "Input method: $CURRENT"

status=0
./gradlew --console=plain connectedDebugAndroidTest || status=$?

# Gradle names no test unless one fails: list each with its outcome.
for result in app/build/outputs/androidTest-results/connected/debug/TEST-*.xml; do
  [ -f "$result" ] || continue
  python3 - "$result" <<'PY'
import sys
import xml.etree.ElementTree as ET

for case in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    if case.find("failure") is not None or case.find("error") is not None:
        outcome = "FAILED"
    elif case.find("skipped") is not None:
        outcome = "skipped"
    else:
        outcome = "passed"
    print(f"{outcome:8} {case.get('classname').rsplit('.', 1)[-1]}.{case.get('name')}")
PY
done

if [ "$status" -ne 0 ]; then
  adb exec-out screencap -p > "$OUT/screen-after.png" || true
  adb pull "$SCREENSHOTS" "$OUT/" || true
fi
exit "$status"
