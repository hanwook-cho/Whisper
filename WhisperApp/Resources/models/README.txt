GGML Whisper models for the Whisper.cpp engine (.bin) plus the Core ML encoder bundle.

The iOS whisper.xcframework expects the encoder next to the .bin at runtime (same stem:
e.g. ggml-tiny.bin → ggml-tiny-encoder.mlmodelc). Both must be in the app bundle.

Setup (automated in this repo):

1. Vendor framework: from repo root run `./scripts/setup-whisper-vendor.sh`
2. Model + encoder: run `./scripts/download-whisper-model.sh` (defaults to ggml-tiny.bin
   and ggml-tiny-encoder.mlmodelc from Hugging Face), then `xcodegen generate` from the repo
   root so Xcode copies those files into the app (new files are not picked up automatically).

Or download manually from https://huggingface.co/ggerganov/whisper.cpp/tree/main
— for each ggml-*.bin you need the matching *-encoder.mlmodelc.zip, unzipped so the
*-encoder.mlmodelc folder sits beside the .bin here. Add both to the WhisperApp target if needed.

The app searches (in order): models/ggml-tiny.bin, models/ggml-base.bin, models/ggml-base.en.bin,
models/ggml-small.bin, then the same names at the bundle root.

For Korean + English, prefer multilingual models (e.g. ggml-base.bin). ggml-base.en.bin is English-only.

Note: `*.bin` and `*-encoder.mlmodelc/` are gitignored by default due to size; clone fresh
and run `download-whisper-model.sh`, or `git add -f` specific files if you choose to commit them.
