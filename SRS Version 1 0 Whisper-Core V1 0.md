# SRS Version 1.0: Whisper-Core V1.0

**1. Introduction**

**1.1 Purpose**

This document specifies the functional and non-functional requirements for the **Whisper-Core** iOS module, a developer-centric tool for high-performance voice-to-text. It enables reliable transcription in noisy (stations, cafes) and quiet (libraries) environments.


**1.2 Product Scope**

Whisper-Core is a Swift Package (SPM) providing an engine-agnostic API that toggles between Apple's native `SFSpeechRecognizer` and a local `Whisper.cpp` implementation (via a vendored `whisper.xcframework`). It targets iOS applications requiring messaging and live captioning capabilities.


---

**2. General Description**

**2.1 Product Perspective**

Whisper-Core acts as an intermediary layer between raw hardware audio input and application-level text output. It integrates with the Apple Neural Engine (ANE) via CoreML for local AI inference and external REST APIs for cloud processing. 


**2.2 User Characteristics**

- **End Users:** Individuals using host apps in loud commuter hubs or quiet public spaces.
- **Developers:** iOS engineers integrating the module via Swift Package Manager.

---

**3. Functional Requirements**

**3.1 Audio Pipeline & DSP (Digital Signal Processing)**

- **REQ-1 (Noise Suppression):** The system shall utilize `AVAudioEngine` with `VoiceProcessingAU` to suppress background clatter (e.g., train station noise) before inference.
- **REQ-2 (Auto-Gain):** The system shall automatically adjust input gain to normalize "low-volume" (whisper) signals to optimal levels for AI model consumption.
- **REQ-3 (Voice Activity Detection):** The module shall implement VAD to trigger transcription only when speech is detected, minimizing idle CPU/ANE usage.

**3.2 Transcription Engines**

- **REQ-4 (Native Engine):** The module shall wrap Apple's [**SFSpeechRecognizer**](https://developer.apple.com/documentation/speech/sfspeechrecognizer) for fast, system-level dictation.
- **REQ-5 (AI Engine):** The module shall integrate **Whisper.cpp** via a **Swift PM binary target** (`whisper.xcframework`) and the published **C API**, linking **Core ML** and **Metal** where available, with **CPU fallback** if GPU initialization fails. Transcription shall support **multilingual** GGML models (including **English** and **Korean**) when the bundled weights support those languages.
- **REQ-5.1 (iOS model artifacts):** On iOS, the official xcframework build expects **two** bundled resources per model stem: a GGML **`.bin`** file (e.g. `ggml-tiny.bin`) and the matching **Core ML encoder directory** (e.g. `ggml-tiny-encoder.mlmodelc`) in the same relative layout as required at runtime (typically under `Resources/models/`). The module shall surface a distinct error (**`WhisperCoreError.whisperCoreMLEncoderNotFound`**) if the encoder bundle is missing from the app.
- **REQ-6 (Cloud Wrapper):** The system shall provide a generic REST wrapper to forward audio buffers to any external Whisper-compatible API (e.g., OpenAI).

**3.3 Multi-Mode Logic**

- **REQ-7 (Local Mode):** 100% on-device processing via CoreML/ANE for maximum privacy.
    - REQ-7.1: Apple Built-in SFSpeechRecognizer
    - REQ-7.2: Whisper.cpp
- **REQ-8 (Hybrid Mode):** The system shall attempt local transcription and automatically failover to Cloud if local confidence scores fall below a configurable threshold.
- REQ-9 (Cloud Mode): 100% Cloud

---

**4. External Interface Requirements**

**4.1 Developer API (The Module)**

- **Streaming Interface:** A real-time token stream for live captioning UI.
- **Block Interface:** An `async/await` function returning a completed `String` for messaging apps.

**4.2 Test App (V1)**

- **Engine Settings:** A slide-over menu to toggle:
    - **Source:** (Apple vs. Whisper.cpp)
    - **Mode:** (Local vs. Cloud vs. Hybrid)
    - **DSP Toggle:** (On/Off to compare noise suppression quality)
- **The "Captioner" Tab:** A live view showing text appearing as you speak (Simulating TikTok-style captions).
- **The "Messenger" Tab:** A "Hold to Talk" button that sends a message to a mock chat thread.

---

- **Environment Presets:** Dedicated test buttons for "Library" (low volume) and "Station" (high noise) to validate DSP effectiveness. At “Station”, high noise should be injected to input voice.

---

**5. Non-Functional Requirements**

**5.1 Performance & Scalability**

- **Latency:** Local transcription for phrases under 5 seconds shall complete in < 800ms on ANE-equipped devices (iPhone 12+).
- **Model Footprint:** The local multilingual "Base" model shall not exceed 150MB in storage.
- **Deployment target:** The Whisper-Core package and sample app target **iOS 16.4+** to match the minimum platform of the bundled `whisper.xcframework`.

**5.2 Security & Privacy**

- **Data Isolation:** In "Local Mode," no audio or text data shall be transmitted off-device.
- **API Security:** The generic cloud wrapper must support secure header injection for API keys/tokens.

---

**6. Implementation Status & Roadmap**

*Done (baseline):*

1. **Whisper.cpp on iOS:** `whisper.xcframework` vendored via **`scripts/setup-whisper-vendor.sh`**, consumed as an SPM binary target; **`WhisperCppEngine`** loads GGML + Core ML encoder, resamples to 16 kHz, materializes models to Application Support.
2. **Model fetch:** **`scripts/download-whisper-model.sh`** retrieves default **`ggml-tiny.bin`** and the matching **`*-encoder.mlmodelc`** from Hugging Face; documentation requires **`xcodegen generate`** after new resources are added.
3. **Sample app:** SwiftUI harness with configurable engine/mode; bundle ID **`com.hwcho.WhisperApp`** (configurable in **`project.yml`**).

*Remaining / stretch:*

1. **Hybrid confidence:** Wire measurable confidence scores and configurable cloud failover thresholds (**REQ-8**).
2. **DSP validation:** Baseline **`AVAudioEngine`** / VoiceProcessing behavior against standard pub/station noise profiles and document WER/RTF in the test plan.
3. **Optional:** Additional GGML model sizes, or custom Core ML / conversion workflows beyond upstream-published encoder bundles.

# Test Plan

**1. Key Performance Indicators (KPIs)**

The module's success will be measured by these standard industry benchmarks:

- **Word Error Rate (WER)**: The percentage of incorrect words (substitutions, deletions, insertions).
    - **Target (Clean)**: < 3% for English; < 5% for Korean.
    - **Target (Noisy)**: < 15% in high-ambient noise (70dB+).
- **Real-Time Factor (RTF)**: The ratio of processing time to audio duration. Target: < 0.5 (e.g., 10s of audio processes in under 5s).
- **Confidence Score**: A value from `0.0` to `1.0` used to trigger the **Hybrid Mode** failover to Cloud if the score drops below `0.7`.

**2. Test Matrix: Environmental Scenarios**

| **Environment** | **Noise Level** | **Primary Focus** | **Success Criteria** |
| --- | --- | --- | --- |
| **Silent Library** | < 30dB | **Whisper Detection** | Detect low-gain signals using vDSP boost. |
| **Train Station** | 75-85dB | **Clatter Rejection** | Filter high-frequency metal screeches/announcements. |
| **Busy Cafe** | 60-70dB | **Speech Separation** | Isolate near-field voice from background "babble." |
| **Roadside** | 80dB | **Low-Freq Rumble** | High-pass filter effectiveness on engine/wind noise. |

**3. Automated Test Strategy**

To ensure consistent results, we will use **Audio Injection** rather than live speaking for every test:

1. **Ground Truth Creation**: Record 50 "Golden Phrases" in English and Korean in a studio (clean audio).
2. **Noise Synthesis**: Use `ffmpeg` or `AudioIDM` to mix clean phrases with curated noise datasets (café ambience, traffic, etc.) at specific **Signal-to-Noise Ratios (SNR)**.
3. **Automated Injection**: Use a framework like [**Perfecto**](https://www.perfecto.io/blog/test-voice-recognition-perfecto) or a custom script to "inject" these noisy files directly into the `AVAudioEngine` tap of the test app.
4. **Accuracy Analysis**: Compare the output against the ground truth using the jiwer Python package to calculate WER.

**4. Regression & Edge Case Testing**

- **Switching Engines**: Rapidly toggle between `appleNative` and `whisperCPP` while audio is playing to ensure no memory leaks or crashes.
- **Code-Switching**: Test phrases that mix English and Korean (e.g., "지금 홍대 cafe에 있어") to verify multilingual model robustness.
- **Thermal Stress**: Run local inference continuously for 10 minutes to monitor for **thermal throttling** on the iPhone, which can degrade RTF

# Possible Data Sets

**1. Mozilla Common Voice**

This is a multilingual corpus of speech data ideal for testing your **Korean** and **English** modules.

- **Official Portal**: Visit the [**Mozilla Data Collective**](https://datacollective.mozillafoundation.org/organization/cmfh0j9o10006ns07jq45h7xk) or the [**Common Voice Datasets page**](https://commonvoice.mozilla.org/datasets).
- **Access Methods**:
    - **Direct Download**: You can download specific language bundles (e.g., "ko" or "en") directly from the browser after providing an email address.
    - **Developer API**: Use the [**Mozilla Data Collective Python SDK**](https://github.com/common-voice/cv-dataset) to load dataframes directly into your test scripts.
    - **Third-Party Platforms**: Versions are often mirrored on Hugging Face Datasets and [**Kaggle**](https://www.kaggle.com/datasets/mozillaorg/common-voice).

**2. Google AudioSet**

This dataset is a collection of 10-second sound clips from YouTube, perfect for sourcing **ambient noise** like "train stations" or "cafes."

- **Official Portal**: Access the [**Google Research AudioSet Page**](https://research.google.com/audioset/download.html).
- **Access Methods**:
    - **Metadata/Ontology**: Google provides CSV files with YouTube IDs and timestamps. You will need a script to download the actual audio.
    - **Direct Audio Clips**: Because the official release is primarily metadata, developers often use community-maintained versions on [**Kaggle (AudioSet Raw WAV)**](https://www.kaggle.com/datasets/zfturbo/audioset) or [**Hugging Face**](https://huggingface.co/datasets/agkphysics/AudioSet) that provide pre-extracted audio files.
    - **CLI Tools**: You can use the [**audioset-download**](https://github.com/MorenoLaQuatra/audioset-download) Python library to download specific labels (like "Speech" or "Train") automatically.
