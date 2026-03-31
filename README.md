# Whisper

iOS sample app (**WhisperApp**) and Swift package (**WhisperCore**) for voice-to-text: native `SFSpeechRecognizer`, a Whisper.cpp placeholder path, and a cloud REST wrapper, with shared audio DSP and engine orchestration.

## Requirements

- **Xcode** (recent release; project was validated with Xcode 26.x)
- **iOS 16.4+** deployment target (matches the whisper.cpp xcframework)
- **Swift** 6 toolchain (app target); **WhisperCore** compiles with **Swift 5 language mode** inside the Swift 6 package (see `Package.swift`)
- Optional: **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** if you change `project.yml` and need to regenerate the Xcode project

## Repository layout

| Path | Description |
|------|--------------|
| `WhisperApp/` | SwiftUI app: Captioner tab, Messenger tab, settings (engine, mode, DSP, **audio processing v1.0 / v1.1**) |
| `WhisperCore/` | Swift Package: library sources under `Sources/WhisperCore/`, tests under `Tests/WhisperCoreTests/` |
| `Whisper.xcworkspace` | Open this in Xcode to work on the app and the package together |
| `Whisper.xcodeproj` | iOS app project (links local **WhisperCore** package) |
| `project.yml` | XcodeGen spec used to generate `Whisper.xcodeproj` |
| `docs/` | Extra maintainer notes (e.g. live captioning debugging) |
| `scripts/` | `setup-whisper-vendor.sh` (xcframework), `download-whisper-model.sh` (GGML `.bin` + Core ML `*-encoder.mlmodelc` into `WhisperApp/Resources/models/`) |
| `*.md` (root) | Design and SRS notes (e.g. Whisper-Core module architecture and requirements) |

## Open and run

1. Open **`Whisper.xcworkspace`** (recommended) or **`Whisper.xcodeproj`**.
2. Select the **WhisperApp** scheme and an **iOS Simulator** or device.
3. Build and run (**⌘R**).

The app declares microphone usage for live transcription; grant the permission when prompted.

## Whisper.cpp (local engine)

The **WhisperCore** package links Apple’s prebuilt **`whisper.xcframework`** from [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases) (see `WhisperCore/Package.swift`). After cloning, run once from the repo root:

```bash
./scripts/setup-whisper-vendor.sh
./scripts/download-whisper-model.sh
xcodegen generate
```

The last step is required whenever new files appear under `WhisperApp/Resources/` (for example after the first Core ML encoder download). XcodeGen updates **Copy Bundle Resources**; without it, the `.bin` may be bundled but not the `*-encoder.mlmodelc` folder, which causes `whisperCoreMLEncoderNotFound` at runtime.

- **`setup-whisper-vendor.sh`** — downloads **v1.8.4** (override with `WHISPER_XCFRAMEWORK_VERSION`) and extracts `whisper.xcframework` into `WhisperCore/Vendor/`.
- **`download-whisper-model.sh`** — downloads **`ggml-tiny.bin`** and the matching **`ggml-tiny-encoder.mlmodelc`** (from the `*-encoder.mlmodelc.zip` on Hugging Face) into `WhisperApp/Resources/models/`. The iOS xcframework is built with Core ML; whisper.cpp resolves the encoder path from the `.bin` name, so both artifacts are required. Use `MODEL_NAME=ggml-base.bin` (or `MODEL_URL=…`) for a larger model (the script derives the encoder zip name from the bin filename).

Large files are **gitignored** (see `.gitignore`); new clones should run both scripts locally. Without a `.bin`, selecting **Whisper.cpp** returns `WhisperCoreError.whisperModelNotFound`. Without the bundled **`*-encoder.mlmodelc`**, you get `WhisperCoreError.whisperCoreMLEncoderNotFound`. Details: `WhisperApp/Resources/models/README.txt`.

On device, Whisper.cpp loads the model from a **copy** under **Application Support** (`WhisperCpp/`) so mmap/open works reliably (avoids `fopen` / errno 2 with some bundle URLs). If Metal/GPU init fails (e.g. pre-M5), the engine **retries CPU-only** automatically.

## Regenerate the Xcode project

If you edit `project.yml`:

```bash
cd /path/to/Whisper
xcodegen generate
```

This overwrites **`Whisper.xcodeproj`**. Commit both `project.yml` and the updated project when the layout changes.

## Swift package only

From `WhisperCore/`:

```bash
swift build
```

The package is **iOS-only**; use **File → Packages → …** in Xcode or integrate via the app’s existing local package reference for device/simulator builds.

Run tests in Xcode (**WhisperCoreTests**) or:

```bash
cd WhisperCore
swift test
```

(Availability of `swift test` for iOS-only packages depends on your toolchain; Xcode’s test runner is the reliable path.)

## Architecture (summary)

- **WhisperCore** – Facade (`WhisperCore.shared`): block and streaming transcription APIs.
- **AudioProcessingHub** – `AVAudioEngine`, voice processing (`setVoiceProcessingEnabled`), VAD, optional noise simulation.
- **EngineOrchestrator** – Chooses native vs Whisper.cpp vs cloud by mode and `EngineConfig`.
- **Engines** – `NativeEngine` (Speech), `WhisperCppEngine` (whisper.cpp + GGML + Core ML encoder), `CloudEngine` (multipart REST example).

### Audio processing versions (`EngineConfig.audioPipeline`)

| Pipeline | Behavior |
|----------|-----------|
| **Original (v1.0)** | Raw VAD gating for streaming (no hysteresis). No envelope AGC on the live tap. Single-utterance (Messenger) uses legacy **×2** gain only when peak &lt; 0.1. |
| **Enhanced (v1.1)** | Per-buffer DC removal, **envelope AGC** (target RMS, attack/release, min/max gain), **soft limiter**, and **VAD hysteresis** (open/close streaks) before engines receive audio. Default in the sample app. |

Configure via **`AudioProcessingPipeline`** on **`EngineConfig`**. The sample app exposes this under **Settings → DSP & Simulation → Audio processing**.

See the root **Design Document** and **SRS** for full requirements and roadmap (Core ML, whisper.cpp, hybrid failover, test scenarios).

For **symptoms, log patterns, and fixes** around first-session live captioning, the volume meter, and Speech vs `AVAudioEngine` ordering, see **`docs/debugging-live-captioning.md`**.

## License

Add a `LICENSE` file if you plan to distribute this project.
