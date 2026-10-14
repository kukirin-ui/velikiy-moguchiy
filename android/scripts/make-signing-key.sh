#!/bin/sh
# Makes the release signing key for the Android APK and prints the GitHub secrets to add.
# Run once on your own machine and keep the .jks file and the password safe: an APK signed
# with a different key cannot update an installed one.
#
#   android/scripts/make-signing-key.sh [path/to/release.jks]
set -eu

KEYSTORE="${1:-velikiy-moguchiy-release.jks}"
ALIAS="velikiy-moguchiy"

if [ -e "$KEYSTORE" ]; then
  echo "$KEYSTORE already exists" >&2
  exit 1
fi

printf "Keystore password (6+ characters): "
stty -echo; read -r PASSWORD; stty echo; echo

keytool -genkeypair -v -keystore "$KEYSTORE" -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$PASSWORD" -keypass "$PASSWORD" -dname "CN=Velikiy Moguchiy"

cat <<NEXT

Add the secrets (GitHub CLI, from the repository folder):

  base64 < "$KEYSTORE" | gh secret set ANDROID_KEYSTORE_BASE64
  gh secret set ANDROID_KEYSTORE_PASSWORD   # paste the password
  gh secret set ANDROID_KEY_ALIAS --body "$ALIAS"
  gh secret set ANDROID_KEY_PASSWORD        # the same password

Never commit $KEYSTORE.
NEXT
