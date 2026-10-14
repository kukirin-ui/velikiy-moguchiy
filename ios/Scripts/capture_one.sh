#!/bin/zsh
# usage: capture_one.sh <out-name> <keyboard-id> [kind] [landscape]
# Headless (simctl only, no Simulator.app): makes <keyboard-id> the default keyboard,
# relaunches the debug app with a focused field of the given kind
# (number|decimal|web|url|email|twitter|numpunct, empty = text editor) and takes light + dark shots
# into screenshots/compare/<out-name>-{light,dark}.png.
# Env: VELIKIY_MOGUCHIY_SIM_UDID overrides the simulator. Bundle ids are those of the Debug
# build (Config/Secrets.xcconfig, else the public defaults in Config/Debug.xcconfig).
set -e
name=$1; first=$2; kind=${3:-}; landscape=${4:-}
cd "${0:A:h:h}"
UDID=${VELIKIY_MOGUCHIY_SIM_UDID:-F6BBEB11-1907-41D0-B25A-13AAF4CB78BB}
source Scripts/xcconfig.zsh
APP_ID=$(xcconfig_setting Debug VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER)
mkdir -p screenshots/compare
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleKeyboards -array "$first" "ru_RU@sw=Russian;hw=Automatic" "en_US@sw=QWERTY;hw=Automatic" "emoji" "$(xcconfig_setting Debug VELIKIY_MOGUCHIY_KEYBOARD_RU_BUNDLE_IDENTIFIER)" "$(xcconfig_setting Debug VELIKIY_MOGUCHIY_KEYBOARD_EN_BUNDLE_IDENTIFIER)"
xcrun simctl shutdown "$UDID"
python3 - "$first" "$UDID" <<'PY'
import plistlib, os, sys
first, udid = sys.argv[1], sys.argv[2]
path = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Preferences/com.apple.keyboard.preferences.plist")
d = plistlib.load(open(path, "rb"))
d["KeyboardLastUsed"] = first
for k in ("KeyboardDidShowGestureKeyboardIntroduction", "DidShowGestureKeyboardIntroduction", "KeyboardDidShowSlideToTypeIntroduction"):
    d[k] = True
lang = d.setdefault("KeyboardLastUsedForLanguage", {})
ru = "ru" in first.lower()
lang["ASCIICapable"] = first if not ru else lang.get("ASCIICapable", first)
lang["en_US"] = first if not ru else lang.get("en_US", first)
lang["NonASCII"] = first if ru else lang.get("NonASCII", first)
lang["ru_RU"] = first if ru else lang.get("ru_RU", first)
plistlib.dump(d, open(path, "wb"))
PY
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
sleep 5; xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true; sleep 1
env SIMCTL_CHILD_VELIKIY_MOGUCHIY_TRYOUT=1 SIMCTL_CHILD_VELIKIY_MOGUCHIY_TRYOUT_KIND="$kind" \
  SIMCTL_CHILD_VELIKIY_MOGUCHIY_TRYOUT_LANDSCAPE=$([[ -n "$landscape" ]] && echo 1 || echo 0) \
  SIMCTL_CHILD_VELIKIY_MOGUCHIY_DASHSCOPE_API_KEY=sk-placeholder-not-real \
  xcrun simctl launch "$UDID" "$APP_ID" >/dev/null
sleep 7
xcrun simctl io "$UDID" screenshot "screenshots/compare/$name-light.png" >/dev/null 2>&1
xcrun simctl ui "$UDID" appearance dark; sleep 3
xcrun simctl io "$UDID" screenshot "screenshots/compare/$name-dark.png" >/dev/null 2>&1
xcrun simctl ui "$UDID" appearance light
