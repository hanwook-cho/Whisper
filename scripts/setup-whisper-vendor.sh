#!/usr/bin/env bash
# Downloads the official whisper.cpp xcframework release and extracts it to WhisperCore/Vendor
# so Swift Package Manager can link the `whisper` binary target (see WhisperCore/Package.swift).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/WhisperCore/Vendor/whisper.xcframework"
VERSION="${WHISPER_XCFRAMEWORK_VERSION:-v1.8.4}"
ZIP_NAME="whisper-${VERSION}-xcframework.zip"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/${ZIP_NAME}"
TMP="$(mktemp -d)"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Downloading ${URL} ..."
curl -sL -o "$TMP/$ZIP_NAME" "$URL"
unzip -q "$TMP/$ZIP_NAME" -d "$TMP/extract"

# Release zip may contain whisper.xcframework at root or under build-apple/
if [[ -d "$TMP/extract/whisper.xcframework" ]]; then
  SRC="$TMP/extract/whisper.xcframework"
elif [[ -d "$TMP/extract/build-apple/whisper.xcframework" ]]; then
  SRC="$TMP/extract/build-apple/whisper.xcframework"
else
  echo "Could not find whisper.xcframework inside the zip." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
echo "Installed: $DEST"
