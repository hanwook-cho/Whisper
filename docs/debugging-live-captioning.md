# Debugging live captioning (Captioner)

This note records symptoms, causes, and fixes for issues where **live captions and the volume meter worked only after stopping and starting again**, or where **settings** did not appear. It is meant for future maintainers changing audio, Speech, or SwiftUI around the Captioner flow.

## Symptoms observed

| Symptom | Notes |
|--------|--------|
| Volume meter flat on first **Start Captioning**; OK on second | Mic permission could already be granted. |
| No on-screen transcription on first try; OK after **Stop** then **Start** | Same session-ordering class of bugs. |
| Logs showed `engine.prepare()+start() OK` but **no** `Captioner tap #1` on first run | Second run showed `Captioner tap #1` and Speech partials. |
| Settings (gear) not visible | Toolbar attached to `TabView` without a navigation bar. |

## Architecture touchpoints (for orientation)

- **`WhisperCore.startLiveCaptioning`** – Orders: mic permission → `prepareSessionForLiveCaptioning` → Speech authorization (Apple path) → `AudioProcessingHub.startStreaming` → `NativeEngine.runLiveCaptioning` consuming the buffer stream.
- **`AudioProcessingHub.startStreaming`** – `AsyncThrowingStream` **producer** runs when the **first** consumer iterates `for try await` (lazy). Installs **mixer** tap, `engine.start()`, yields PCM buffers.
- **`NativeEngine.runLiveCaptioning`** – Appends buffers to `SFSpeechAudioBufferRecognitionRequest` after creating `SFSpeechRecognitionTask`.

## Issue 1: Speech session before the audio engine (ordering)

**Cause:** `speechRecognizer.recognitionTask(with:)` was created **before** `for try await buffer in bufferStream`. The buffer stream’s producer (mixer tap + `engine.start()`) only runs when that loop **starts**. So Speech could configure `AVAudioSession` **before** `AVAudioEngine` was running, leaving the mixer tap idle until a later stop/start “fixed” routing.

**Fix:** Create `SFSpeechRecognitionTask` **inside** the buffer loop, on **first** buffer (`recognitionTask == nil`), so the engine and tap start **before** Speech attaches.

**File:** `WhisperCore/Sources/WhisperCore/NativeEngine.swift` (`runLiveCaptioning`).

## Issue 2: Mixer tap never fires on first cold start

**Cause:** Even with correct ordering, **`engine.start()`** could return success while the render graph delivered **no** mixer tap callbacks on the **first** start after a fresh graph. The **second** session often worked because stop/remove tap + start behaved like a warm path.

**Evidence:** Logs with `Captioner engine.prepare()+start() OK` but **missing** `Captioner tap #1 pass-through` until a second user attempt.

**Fix:** After the first `engine.start()`, schedule a **one-time** recovery (~320 ms on the main queue): if **no** tap buffer was counted yet, log, `removeMixerTapIfNeeded()`, reinstall the tap, `engine.start()` again **once** (no infinite retries). First tap callback cancels the scheduled work.

**File:** `WhisperCore/Sources/WhisperCore/AudioProcessingHub.swift` (`startStreaming`).

## Issue 3: Level meter UI tied to a single `AsyncStream` continuation

**Cause:** `audioLevelStream()` stored **one** `Continuation`. A second subscription (e.g. SwiftUI lifecycle calling `audioLevelStream()` again) **replaced** the continuation; the older `for await` loop never received `yield`s.

**Fix:** Broadcast each normalized level to **all** registered continuations (dictionary keyed by id, remove on termination).

**File:** `AudioProcessingHub.swift` (`broadcastLevel`, `audioLevelStream`).

## Issue 4: Mic / session readiness

**Cause:** `AVAudioSession.setActive(true)` and engine start can race the first **microphone** grant or route stabilization.

**Fix:** `ensureRecordPermission()` before preparing the session; optional **`ensureMicrophonePermission()`** from the app (`onAppear`) to pre-warm dialogs. Call **`engine.prepare()`** immediately before **`engine.start()`** in streaming paths.

**Files:** `AudioProcessingHub.swift`, `WhisperCore.swift` (public APIs), `WhisperApp/ContentView.swift` (`onAppear`).

## Issue 5: Settings gear not visible

**Cause:** `.toolbar { … }` on **`TabView`** does not get a standard navigation bar on iPhone.

**Fix:** Wrap each tab in **`NavigationStack`**, set `.navigationTitle` / `.toolbar` there, keep `.sheet` for `SettingsView`.

**File:** `WhisperApp/ContentView.swift`.

## Log cheat sheet

When diagnosing a “first start silent” report, look for this **healthy** sequence after **Start Captioning** (Apple path):

1. `startLiveCaptioning: … source=appleNative …`
2. `prepareSessionForLiveCaptioning: …` (first launch may also log `setupAudioSession: graph attached …`)
3. `Captioner startStreaming: sampleRate=…`
4. `Captioner engine.prepare()+start() OK`
5. **`Captioner tap #1 pass-through …`** (proves mixer tap is delivering audio)
6. **`NativeEngine live: recognition task started after first tap buffer`**
7. **`NativeEngine live: partial len=…`**

If (5) is missing for several hundred milliseconds, the **silent-start recovery** may log:

- `Captioner: no mixer tap buffers after start — stopping and restarting engine once`

followed by (5)–(7) on the automatic retry.

## Related APIs (public)

| API | Purpose |
|-----|--------|
| `WhisperCore.ensureSpeechAuthorization()` | Pre-resolve Speech permission before live capture. |
| `WhisperCore.ensureMicrophonePermission()` | Pre-resolve mic permission. |
| `WhisperCoreError.speechRecognitionDenied` / `.microphoneDenied` | User-facing errors for denied permissions. |

## Swift details worth remembering

- **`AsyncThrowingStream`** from `startStreaming` runs its **builder** when the **first** consumer begins iteration, not when `startStreaming()` returns.
- Only **one** `installTap` per mixer bus at a time; removal must not run synchronously from inside the tap callback (use main queue / async handoff for utterance completion paths elsewhere in the hub).

---

*Last updated to reflect fixes validated in development (session ordering, cold-start tap recovery, level broadcast, navigation, mic/Speech pre-warm).*
