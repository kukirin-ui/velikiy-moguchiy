#!/bin/bash
# Prints a folder with sherpa-onnx static libraries built without text-to-speech,
# for SHERPA_ONNX_LIB_DIR. The default download of the sherpa-onnx-sys crate
# includes TTS, which statically links espeak-ng (GPL-3.0) into the app; the
# no-TTS build leaves it out. The crate still asks the linker for the TTS
# libraries, so they are replaced by empty archives.
set -euo pipefail

VERSION=1.13.4
NAME="sherpa-onnx-v${VERSION}-osx-arm64-static-no-tts-lib"
SHA256=ca356bdd4fefc1245a2c30f2a5da5db5523430be941e72692b86df3e62424fb5
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/target/sherpa-onnx"
LIB="$ROOT/$NAME/lib"

if [ ! -f "$LIB/.complete" ]; then
  mkdir -p "$ROOT"
  ARCHIVE="$ROOT/$NAME.tar.bz2"
  if ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --status 2>/dev/null; then
    curl -fsSL -o "$ARCHIVE" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
    echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --status || { echo "sherpa-onnx: checksum mismatch" >&2; exit 1; }
  fi
  rm -rf "$ROOT/$NAME"
  tar -xjf "$ARCHIVE" -C "$ROOT"
  EMPTY="$ROOT/empty.o"
  echo "" | xcrun clang -c -x c -arch arm64 - -o "$EMPTY"
  for stub in espeak-ng piper_phonemize ucd; do
    [ -f "$LIB/lib$stub.a" ] || xcrun ar rcs "$LIB/lib$stub.a" "$EMPTY" 2>/dev/null
  done
  touch "$LIB/.complete"
fi
echo "$LIB"
