#!/bin/zsh
# Builds an unsigned device IPA of VelikiyMoguchiy (app, RU/EN keyboards, Live Activity
# widget) for CI and releases:
#
#   dist/VelikiyMoguchiy-iOS-unsigned.ipa   (or the path given as the first argument)
#
# The IPA carries no signature and no entitlements: sign it with your own tools (see
# README, «Установка готовой сборки»). Unlike Scripts/build-ipa.sh this script does not
# run the keyboard-parity gate (it needs simulator screenshots of Apple's keyboard) and
# builds neither the ad-hoc nor the KeyboardKit variant. Bundle ids and App Group come
# from Config/Secrets.xcconfig or the public defaults in Config/Release.xcconfig.
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/xcconfig.zsh
require_renamed_secrets

IPA=${1:-dist/VelikiyMoguchiy-iOS-unsigned.ipa}
IPA=${IPA:a}
OUT=build/ci-ipa
rm -rf "$OUT"
mkdir -p "$OUT" "${IPA:h}"

# MARKETING_VERSION in the environment (CI sets it from a release tag) overrides project.yml.
version_setting=()
[[ -n "${MARKETING_VERSION:-}" ]] && version_setting=("MARKETING_VERSION=$MARKETING_VERSION")

xcodegen generate
xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme VelikiyMoguchiy -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$OUT/derived" \
  -skipPackagePluginValidation -skipMacroValidation -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" "${version_setting[@]}" build

app="$OUT/derived/Build/Products/Release-iphoneos/VelikiyMoguchiy.app"
[[ -d "$app" ]] || { echo "build-unsigned-ipa: $app missing"; exit 1; }
for ext in VelikiyMoguchiyKeyboardRU VelikiyMoguchiyKeyboardEN VelikiyMoguchiyWidgets; do
  [[ -d "$app/PlugIns/$ext.appex" ]] || { echo "build-unsigned-ipa: $ext.appex missing"; exit 1; }
done

staging=$(mktemp -d)
mkdir "$staging/Payload"
ditto "$app" "$staging/Payload/VelikiyMoguchiy.app"
rm -f "$IPA"
# zip (not ditto --sequesterRsrc) so the archive has no __MACOSX entries.
(cd "$staging" && zip -qry "$IPA" Payload)
rm -rf "$staging"
ls -la "$IPA"
