import Foundation
import AVFoundation

final class EngineOrchestrator {
    private let nativeEngine = NativeEngine()
    private let whisperEngine = WhisperCppEngine()
    private let cloudEngine = CloudEngine()
    
    func ensureAppleSpeechAuthorization() async throws {
        try await nativeEngine.ensureSpeechAuthorization()
    }

    /// Live Captioner: one Apple recognition session fed by the tap buffer stream.
    func runAppleLiveCaptioning(
        bufferStream: AsyncThrowingStream<AVAudioPCMBuffer, Error>,
        continuation: AsyncThrowingStream<TranscriptionToken, Error>.Continuation,
        speechLocale: SpeechRecognitionLocale
    ) async {
        await nativeEngine.runLiveCaptioning(
            bufferStream: bufferStream,
            continuation: continuation,
            speechLocale: speechLocale
        )
    }

    func transcribe(buffer: AVAudioPCMBuffer, mode: TranscriptionMode, config: EngineConfig) async throws -> TranscriptionToken {
        WhisperDebugLog.engine.debug(
            "transcribe: mode=\(String(describing: mode)) source=\(String(describing: config.source)) frames=\(buffer.frameLength) format=\(buffer.format.sampleRate)Hz"
        )
        switch mode {
        case .local:
            return try await runLocalInference(buffer: buffer, config: config)
        case .cloud:
            return try await cloudEngine.transcribe(buffer: buffer, config: config)
        case .hybrid:
            do {
                let result = try await runLocalInference(buffer: buffer, config: config)
                // REQ-8: Check confidence for failover
                if result.confidence < 0.7 { throw EngineError.lowConfidence }
                return result
            } catch {
                return try await cloudEngine.transcribe(buffer: buffer, config: config)
            }
        }
    }
    
    private func runLocalInference(buffer: AVAudioPCMBuffer, config: EngineConfig) async throws -> TranscriptionToken {
        switch config.source {
        case .appleNative:
            return try await nativeEngine.transcribe(buffer: buffer, speechLocale: config.speechLocale)
        case .whisperCpp:
            return try await whisperEngine.transcribe(buffer: buffer, config: config)
        }
    }
}

enum EngineError: Error {
    case lowConfidence
}

protocol TranscriptionEngine {
    init()
    func transcribe(buffer: AVAudioPCMBuffer, config: EngineConfig) async throws -> TranscriptionToken
}