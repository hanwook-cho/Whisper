import Foundation
import AVFoundation
import Speech

/// Wraps Apple's SFSpeechRecognizer for native speech-to-text.
final class NativeEngine {
    init() {}

    private static func makeRecognizer(for speechLocale: SpeechRecognitionLocale) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: speechLocale.locale)
    }

    /// Ensures Speech authorization before starting the audio tap so level metering and recognition start together.
    func ensureSpeechAuthorization() async throws {
        let status = await Self.awaitSpeechAuthorization()
        guard status == .authorized else {
            WhisperDebugLog.engine.error("NativeEngine: speech authorization denied status=\(String(describing: status))")
            throw NativeEngineError.speechAuthorizationDenied
        }
    }

    /// One continuous `SFSpeechAudioBufferRecognitionRequest` with partial results — append tap buffers until the stream ends.
    func runLiveCaptioning(
        bufferStream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        continuation: AsyncThrowingStream<TranscriptionToken, Error>.Continuation,
        speechLocale: SpeechRecognitionLocale
    ) async {
        let speechRecognizer = Self.makeRecognizer(for: speechLocale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            WhisperDebugLog.engine.error(
                "NativeEngine: SFSpeechRecognizer unavailable for locale=\(speechLocale.rawValue) (check Speech permission and on-device support in Settings)"
            )
            continuation.finish(throwing: NativeEngineError.recognizerUnavailable)
            return
        }
        // Speech authorization is completed in `WhisperCore.startLiveCaptioning` before the buffer stream starts.

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let finishGuard = LiveStreamFinishGuard()

        // Start Speech only after the first tap buffer exists. If `recognitionTask` is created before
        // `for try await` runs, the AsyncThrowingStream producer (install tap + engine.start) is deferred
        // and SFSpeech can reconfigure `AVAudioSession` first — leaving the mixer tap idle until stop/start.
        var recognitionTask: SFSpeechRecognitionTask?

        do {
            for try await buffer in bufferStream {
                if recognitionTask == nil {
                    recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                        if let result = result {
                            let text = result.bestTranscription.formattedString
                            let token = TranscriptionToken(text: text, confidence: result.isFinal ? 0.95 : 0.8)
                            WhisperDebugLog.engine.debug(
                                "NativeEngine live: partial len=\(text.count) isFinal=\(result.isFinal)"
                            )
                            finishGuard.yield(token, continuation: continuation)
                        }
                        if let error = error {
                            WhisperDebugLog.engine.debug("NativeEngine live handler: \(error.localizedDescription)")
                            if Self.isBenignEndOfStreamError(error) {
                                return
                            }
                            finishGuard.finishThrowing(continuation, error: error)
                        }
                    }
                    WhisperDebugLog.engine.debug("NativeEngine live: recognition task started after first tap buffer locale=\(speechLocale.rawValue)")
                }
                request.append(buffer)
            }
            if recognitionTask != nil {
                request.endAudio()
                try await Task.sleep(nanoseconds: 450_000_000)
            }
            finishGuard.finish(continuation)
        } catch {
            recognitionTask?.cancel()
            finishGuard.finishThrowing(continuation, error: error)
        }
    }

    /// Apple recommends invoking speech authorization on the main thread; doing it from a background `Task` can make the first session flaky until the user tries again.
    private static func awaitSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
    }

    /// Errors that often appear after `endAudio` with little audio; not surfaced to the stream consumer.
    private static func isBenignEndOfStreamError(_ error: Error) -> Bool {
        let ns = error as NSError
        let msg = error.localizedDescription.lowercased()
        if msg.contains("no speech") { return true }
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 203 { return true }
        return false
    }

    func transcribe(buffer: AVAudioPCMBuffer, speechLocale: SpeechRecognitionLocale) async throws -> TranscriptionToken {
        let speechRecognizer = Self.makeRecognizer(for: speechLocale)
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            WhisperDebugLog.engine.error(
                "NativeEngine: SFSpeechRecognizer unavailable for locale=\(speechLocale.rawValue) (check Speech permission and on-device support in Settings)"
            )
            throw NativeEngineError.recognizerUnavailable
        }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = false

        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let task = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    WhisperDebugLog.engine.debug("NativeEngine: recognition result len=\(text.count) isFinal=\(result.isFinal)")
                    continuation.resume(returning: text)
                } else if let error = error {
                    WhisperDebugLog.engine.error("NativeEngine: recognition error \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
            recognitionRequest.append(buffer)
            recognitionRequest.endAudio()
            _ = task
        }
        return TranscriptionToken(text: text, confidence: 0.95)
    }
}

private final class LiveStreamFinishGuard: @unchecked Sendable {
    private var finished = false
    private let lock = NSLock()

    func yield(_ token: TranscriptionToken, continuation: AsyncThrowingStream<TranscriptionToken, Error>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        continuation.yield(token)
    }

    func finish(_ continuation: AsyncThrowingStream<TranscriptionToken, Error>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    func finishThrowing(_ continuation: AsyncThrowingStream<TranscriptionToken, Error>.Continuation, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish(throwing: error)
    }
}

enum NativeEngineError: Error {
    case recognizerUnavailable
    case requestCreationFailed
    case speechAuthorizationDenied
}
