#!/bin/zsh
# usage: capture_pair.sh <name> <first-keyboard-id> [more ids...]
# (the simulator UDID is the iPhone 17 Pro used for development)
# Headless: reorder AppleKeyboards so <first> is the default, reboot the simulator,
# focus the practice field and screenshot light + dark. No Simulator.app window.
set -e
name=$1; shift
cd "${0:A:h:h}"
source Scripts/xcconfig.zsh
APP_ID=$(xcconfig_setting Debug VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER)
first=$1
xcrun simctl spawn booted defaults write .GlobalPreferences AppleKeyboards -array "$@"
xcrun simctl shutdown booted
# The system remembers the last used keyboard; point it at the one to capture.
python3 - "$first" <<'PY'
import plistlib, os, sys
path = os.path.expanduser("~/Library/Developer/CoreSimulator/Devices/F6BBEB11-1907-41D0-B25A-13AAF4CB78BB/data/Library/Preferences/com.apple.keyboard.preferences.plist")
d = plistlib.load(open(path, "rb"))
first = sys.argv[1]
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
xcrun simctl boot "iPhone 17 Pro"; xcrun simctl bootstatus "iPhone 17 Pro" -b >/dev/null
xcrun simctl ui booted appearance light
sleep 6; xcrun simctl terminate booted "$APP_ID" >/dev/null 2>&1 || true; sleep 1
SIMCTL_CHILD_VELIKIY_MOGUCHIY_TRYOUT=1 SIMCTL_CHILD_VELIKIY_MOGUCHIY_DASHSCOPE_API_KEY=sk-placeholder-not-real xcrun simctl launch booted "$APP_ID" >/dev/null
sleep 6
xcrun simctl io booted screenshot screenshots/compare/$name-light.png >/dev/null 2>&1
xcrun simctl ui booted appearance dark; sleep 3
xcrun simctl io booted screenshot screenshots/compare/$name-dark.png >/dev/null 2>&1
xcrun simctl ui booted appearance light
