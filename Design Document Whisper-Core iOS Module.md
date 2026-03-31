# Design Document: Whisper-Core iOS Module

## 1. System Architecture Overview

Whisper-Core uses a **provider-based architecture**. A central orchestrator manages the audio pipeline and delegates transcription to specific engine implementations based on configuration (Native, local Whisper.cpp, or Cloud).

### 1.1 High-Level Component Diagram

- **WhisperCore (Facade):** Public entry point (`WhisperCore.shared`): block and streaming transcription APIs.
- **AudioProcessingHub:** Owns `AVAudioEngine`, optional noise simulation, and VAD-oriented gating for streaming.
- **EngineOrchestrator:** Chooses native vs Whisper.cpp vs cloud from `EngineConfig` and mode (Local / Cloud / Hybrid).
- **TranscriptionEngines:**
    - `NativeEngine` — `SFSpeechRecognizer`
    - `WhisperCppEngine` — whisper.cpp via **`whisper.xcframework`** (GGML weights + Core ML encoder bundle)
    - `CloudEngine` — multipart REST example

---

## 2. Detailed Design

### 2.1 Audio Pipeline & DSP (REQ-1, REQ-2, REQ-3)

The module uses `AVAudioEngine` to tap microphone input. Using `.voiceChat` or `.videoChat` session modes enables system **VoiceProcessingAU** (echo cancellation / noise suppression) where enabled on the input node.

Auto-gain and VAD-oriented behavior are implemented in **AudioProcessingHub** (streaming path) so transcription is not invoked on silent buffers when VAD indicates no speech.

### 2.2 Transcription Engine Abstraction (REQ-4, REQ-5, REQ-6)

Engines are selected by the orchestrator behind a small internal abstraction. The public API does not expose per-engine protocols; configuration is via `EngineConfig` (source: Apple native vs Whisper.cpp vs cloud).

### 2.3 Whisper.cpp on iOS (REQ-5)

**Packaging:** **WhisperCore** declares a Swift PM **binary target** pointing at **`WhisperCore/Vendor/whisper.xcframework`**, fetched by **`scripts/setup-whisper-vendor.sh`** from upstream [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases). Swift calls the C API from the xcframework; the sample app does **not** use a separate Objective-C++ bridging header in the app target.

**Core ML requirement:** The published iOS xcframework is built with **Core ML** enabled. Whisper.cpp resolves the encoder path from the GGML file path: for `ggml-<stem>.bin` it expects **`ggml-<stem>-encoder.mlmodelc`** (a **directory bundle**) in the **same directory**. Both artifacts must therefore be present at runtime.

**Model artifacts (host app):**

| Artifact | Typical source |
|----------|----------------|
| GGML weights | e.g. `ggml-tiny.bin` from Hugging Face `ggerganov/whisper.cpp` |
| Core ML encoder | Matching `*-encoder.mlmodelc.zip`, unzipped to e.g. `ggml-tiny-encoder.mlmodelc` |

**Runtime loading:** `WhisperCppEngine` locates files in **`Bundle.main`** (prefer `Resources/models/`), then **copies** the `.bin` and the `*.mlmodelc` folder to **Application Support** under `WhisperCpp/` so mmap/open behaves reliably on device. If the encoder bundle is missing from the app, initialization fails with **`WhisperCoreError.whisperCoreMLEncoderNotFound`**.

**Project hygiene:** **`scripts/download-whisper-model.sh`** downloads the default `.bin` and the matching encoder zip. After new files appear under **`WhisperApp/Resources/`**, run **`xcodegen generate`** so **Copy Bundle Resources** includes them (XcodeGen only picks up files that exist when the project is generated).

**Audio format:** Incoming `AVAudioPCMBuffer` is converted/resampled to **16 kHz mono float32** for whisper.

**Inference:** GPU/Metal is used when available; the engine **retries CPU-only** if GPU init fails.

### 2.4 Hybrid Mode Logic (REQ-8)

**EngineOrchestrator** implements failover (e.g. to cloud) when local engines fail or confidence thresholds are not met, per configuration.

---

## 3. External Interface (API)

### 3.1 Swift Package Manager API

Consumers use **`WhisperCore.shared`** with **`async`/`await`** and **`AsyncThrowingStream`** for live captioning. See **`WhisperCore.swift`** for the public surface (`transcribe`, `startLiveCaptioning`, etc.).

---

## 4. Test App Implementation (V1)

### 4.1 UI Layout

- **Settings:** Pickers for engine **source** (Apple vs Whisper.cpp), **mode** (Local / Cloud / Hybrid), and DSP-related options.
- **Captioner tab:** Subscribes to the live transcription stream.
- **Messenger tab:** Hold-to-talk flow using the block transcription API.

### 4.2 Environment Simulation

Optional **noise injector** plays looped ambient audio to stress VoiceProcessing / DSP paths.

---

## 5. Technical Stack

| Item | Choice |
|------|--------|
| App language | Swift 6 |
| Package | Swift PM; **WhisperCore** uses Swift 5 language mode under Swift 6 toolchain |
| Minimum iOS | **16.4+** (aligned with bundled `whisper.xcframework`) |
| Whisper.cpp | **Binary xcframework** + Core ML encoder bundle |
| Frameworks | AVFoundation, Speech, Core ML, Metal, Accelerate (as linked by WhisperCore) |
| Sample app project | **XcodeGen** (`project.yml` → `Whisper.xcodeproj`) |
| Sample bundle ID | **`com.hwcho.WhisperApp`** (override in `project.yml`) |

**Logging:** Debug logs use **`os.Logger`** with subsystem **`com.whisper.WhisperCore`** (independent of the app’s bundle identifier).

---

*This document is maintained to match the repository; when behavior changes, update this file alongside code and the SRS.*
