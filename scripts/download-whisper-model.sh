#!/usr/bin/env bash
# Downloads a GGML Whisper .bin and the matching Core ML encoder bundle into
# WhisperApp/Resources/models/ for Whisper.cpp on iOS (xcframework is Core ML–enabled).
# Default: ggml-tiny.bin (~75 MB) + ggml-tiny-encoder.mlmodelc (unzipped from HF).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/WhisperApp/Resources/models"
mkdir -p "$DEST_DIR"

DEFAULT_NAME="${MODEL_NAME:-ggml-tiny.bin}"
DEFAULT_URL="${MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${DEFAULT_NAME}}"

STEM="${DEFAULT_NAME%.bin}"
ENCODER_ZIP_NAME="${STEM}-encoder.mlmodelc.zip"
ENCODER_ZIP_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${ENCODER_ZIP_NAME}"
ENCODER_DIR="$DEST_DIR/${STEM}-encoder.mlmodelc"
OUT_BIN="$DEST_DIR/$DEFAULT_NAME"

need_bin=1
need_encoder=1
[[ -f "$OUT_BIN" ]] && need_bin=0
[[ -d "$ENCODER_DIR" ]] && need_encoder=0

if [[ $need_bin -eq 0 && $need_encoder -eq 0 ]]; then
  echo "Already present: $OUT_BIN and $ENCODER_DIR"
  exit 0
fi

if [[ $need_bin -eq 1 ]]; then
  echo "Downloading $DEFAULT_URL ..."
  echo "Destination: $OUT_BIN"
  curl -fL --progress-bar -o "$OUT_BIN" "$DEFAULT_URL"
  echo "Done: $OUT_BIN ($(du -h "$OUT_BIN" | cut -f1))"
fi

if [[ $need_encoder -eq 1 ]]; then
  TMP_ZIP="$DEST_DIR/$ENCODER_ZIP_NAME"
  echo "Downloading Core ML encoder $ENCODER_ZIP_URL ..."
  curl -fL --progress-bar -o "$TMP_ZIP" "$ENCODER_ZIP_URL"
  unzip -o -q "$TMP_ZIP" -d "$DEST_DIR"
  rm -f "$TMP_ZIP"
  echo "Done: Core ML encoder at $ENCODER_DIR"
fi

echo ""
echo "Next: regenerate the Xcode project so the encoder is copied into the app bundle:"
echo "  xcodegen generate"
echo "(Otherwise Xcode never adds new files under Resources to Copy Bundle Resources.)"
