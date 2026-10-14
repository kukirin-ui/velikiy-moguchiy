#!/bin/zsh
# Builds device IPAs of VelikiyMoguchiy (app + both keyboards + Live Activity widget) for re-signing tools.
#
#   dist/VelikiyMoguchiy-unsigned.ipa             no signature at all
#   dist/VelikiyMoguchiy-adhoc-entitlements.ipa   ad-hoc signature that only carries the
#                                                 entitlements (no certificate), for signers
#                                                 that read entitlements from the binary
#   dist/VelikiyMoguchiy-KK-*.ipa                 the same app with the «Великий & Могучий KK»
#                                                 keyboards (KeyboardKit) next to RU/EN and no
#                                                 Live Activity, for comparing typing
#
# Bundle id and App Group come from Config/Secrets.xcconfig (your values) or
# Config/Release.xcconfig (public defaults), as in the build itself.
# TEAM_PREFIX (default: DEVELOPMENT_TEAM from Secrets.xcconfig plus ".")
# replaces $(AppIdentifierPrefix) in the keychain-access-groups entitlement of
# the ad-hoc variant.
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/xcconfig.zsh
require_renamed_secrets

# No IPA leaves this script unless our RU/EN keyboards match Apple's keyboard
# (Scripts/parity/parity.sh, report in build/parity/report/report.html).
if ! env -u PARITY_CASES -u PARITY_APPEARANCES -u REFRESH_APPLE Scripts/parity/parity.sh; then
  echo "build-ipa: the keyboards differ from Apple's by more than the tolerance; no IPA built."
  echo "build-ipa: see build/parity/report/report.html"
  exit 1
fi
if [[ -z "${TEAM_PREFIX:-}" ]]; then
  TEAM=$(xcconfig_setting Release DEVELOPMENT_TEAM)
  if [[ -z "$TEAM" || "$TEAM" == YOUR_TEAM_ID ]]; then
    echo "build-ipa: set TEAM_PREFIX=<team id>. or DEVELOPMENT_TEAM in Config/Secrets.xcconfig"
    exit 1
  fi
  TEAM_PREFIX="$TEAM."
fi
OUT=build/ipa
rm -rf "$OUT" dist
mkdir -p dist

xcodegen generate >/dev/null
GROUP=$(xcconfig_setting Release VELIKIY_MOGUCHIY_APP_GROUP_IDENTIFIER)
APPID=$(xcconfig_setting Release VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER)
ent() {  # ent <source.entitlements> <dest>
  sed -e "s|\$(VELIKIY_MOGUCHIY_APP_GROUP_IDENTIFIER)|$GROUP|g" \
      -e "s|\$(AppIdentifierPrefix)|$TEAM_PREFIX|g" \
      -e "s|\$(VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER)|$APPID|g" "$1" > "$2"
}
mkdir -p "$OUT/ent"
ent KeyboardExtension/Keyboard.entitlements "$OUT/ent/keyboard.entitlements"
ent App/VelikiyMoguchiy.entitlements "$OUT/ent/app.entitlements"

package() {  # package <app-dir> <ipa-path>
  local staging; staging=$(mktemp -d)
  mkdir "$staging/Payload"
  ditto "$1" "$staging/Payload/VelikiyMoguchiy.app"
  # zip (not ditto --sequesterRsrc) so the archive has no __MACOSX entries.
  (cd "$staging" && zip -qry "$OLDPWD/$2" Payload)
  rm -rf "$staging"
}

variant() {  # variant <scheme> <ipa-name-prefix>
  local derived="$OUT/derived-$1"
  xcodebuild -project VelikiyMoguchiy.xcodeproj -scheme "$1" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build \
    | grep -E "error:|BUILD" || true
  local app="$derived/Build/Products/Release-iphoneos/VelikiyMoguchiy.app"
  [[ -d "$app" ]] || { echo "build failed: $app missing"; exit 1; }
  package "$app" "dist/$2-unsigned.ipa"

  # Ad-hoc variant with entitlements.
  local adhoc="$OUT/adhoc-$1/VelikiyMoguchiy.app"
  mkdir -p "$OUT/adhoc-$1"; rm -rf "$adhoc"; ditto "$app" "$adhoc"
  for ext in "$adhoc"/PlugIns/*.appex; do
    if [[ "$ext" == *VelikiyMoguchiyWidgets.appex ]]; then
      # The Live Activity extension needs no App Group or keychain access.
      codesign -f -s - "$ext"
    else
      codesign -f -s - --entitlements "$OUT/ent/keyboard.entitlements" "$ext"
    fi
  done
  codesign -f -s - --entitlements "$OUT/ent/app.entitlements" "$adhoc"
  package "$adhoc" "dist/$2-adhoc-entitlements.ipa"
}

variant VelikiyMoguchiy VelikiyMoguchiy
variant VelikiyMoguchiyKK VelikiyMoguchiy-KK
cp "$OUT/ent/app.entitlements" dist/app.entitlements.plist
cp "$OUT/ent/keyboard.entitlements" dist/keyboard.entitlements.plist
ls -la dist
