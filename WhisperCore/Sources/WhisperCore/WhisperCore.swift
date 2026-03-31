import Foundation
import AVFoundation

/// The main entry point for the Whisper-Core module.
public final class WhisperCore: @unchecked Sendable {
    public static let shared = WhisperCore()
    
    private let orchestrator: EngineOrchestrator
    private let audioHub: AudioProcessingHub
    
    private init() {
        self.audioHub = AudioProcessingHub()
        self.orchestrator = EngineOrchestrator()
    }
    
    /// Call early (e.g. `onAppear`) so the first live-caption session does not block the mic tap on the Speech permission flow.
    public func ensureSpeechAuthorization() async throws {
        do {
            try await orchestrator.ensureAppleSpeechAuthorization()
        } catch NativeEngineError.speechAuthorizationDenied {
            throw WhisperCoreError.speechRecognitionDenied
        }
    }

    /// Resolves microphone permission before `AVAudioSession` / `AVAudioEngine` start so the first capture session is not silent.
    public func ensureMicrophonePermission() async throws {
        do {
            try await audioHub.ensureRecordPermission()
        } catch AudioHubError.microphoneDenied {
            throw WhisperCoreError.microphoneDenied
        }
    }

    /// REQ-10: Block Interface for discrete transcription (e.g., messaging).
    public func transcribeOnce(mode: TranscriptionMode, config: EngineConfig) async throws -> TranscriptionToken {
        let buffer = try await audioHub.captureSingleUtterance(enableDSP: config.enableDSP)
        return try await orchestrator.transcribe(buffer: buffer, mode: mode, config: config)
    }
    
    /// REQ-9: Streaming Interface for live captioning.
    public func startLiveCaptioning(config: EngineConfig) -> AsyncThrowingStream<TranscriptionToken, Error> {
        AsyncThrowingStream { continuation in
            Task {
                WhisperDebugLog.facade.debug(
                    "startLiveCaptioning: DSP=\(config.enableDSP) source=\(String(describing: config.source)) locale=\(config.speechLocale.rawValue) mode=local"
                )
                do {
                    try await audioHub.ensureRecordPermission()
                } catch AudioHubError.microphoneDenied {
                    WhisperDebugLog.facade.error("startLiveCaptioning: microphone permission denied")
                    continuation.finish(throwing: WhisperCoreError.microphoneDenied)
                    return
                } catch {
                    WhisperDebugLog.facade.error("startLiveCaptioning: mic permission check failed \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }
                do {
                    try audioHub.prepareSessionForLiveCaptioning(enableDSP: config.enableDSP)
                } catch {
                    WhisperDebugLog.facade.error("startLiveCaptioning: audio session failed \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }
                if config.source == .appleNative {
                    do {
                        try await orchestrator.ensureAppleSpeechAuthorization()
                    } catch NativeEngineError.speechAuthorizationDenied {
                        WhisperDebugLog.facade.error("startLiveCaptioning: speech authorization denied")
                        continuation.finish(throwing: WhisperCoreError.speechRecognitionDenied)
                        return
                    } catch {
                        WhisperDebugLog.facade.error("startLiveCaptioning: speech auth failed \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                        return
                    }
                }
                // Apple: pass full tap stream to Speech (no VAD). Whisper.cpp: gate to avoid flooding the chunked engine.
                let bufferStream = audioHub.startStreaming(
                    enableDSP: config.enableDSP,
                    gateWithVAD: config.source == .whisperCpp
                )
                switch config.source {
                case .appleNative:
                    await orchestrator.runAppleLiveCaptioning(
                        bufferStream: bufferStream,
                        continuation: continuation,
                        speechLocale: config.speechLocale
                    )
                case .whisperCpp:
                    do {
                        var chunkIndex = 0
                        for try await buffer in bufferStream {
                            chunkIndex += 1
                            WhisperDebugLog.facade.debug(
                                "startLiveCaptioning: whisper chunk #\(chunkIndex) frameLength=\(buffer.frameLength)"
                            )
                            let token = try await orchestrator.transcribe(buffer: buffer, mode: .local, config: config)
                            let preview = token.text.prefix(120)
                            WhisperDebugLog.facade.debug(
                                "startLiveCaptioning: token conf=\(token.confidence) text=\"\(String(preview))\""
                            )
                            continuation.yield(token)
                        }
                        WhisperDebugLog.facade.debug("startLiveCaptioning: buffer stream ended normally")
                        continuation.finish()
                    } catch {
                        WhisperDebugLog.facade.error("startLiveCaptioning: stream error \(String(describing: error))")
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    public func audioLevelStream() -> AsyncStream<Float> {
        audioHub.audioLevelStream()
    }

    public func simulateNoise(enabled: Bool) {
        if enabled {
            audioHub.playSimulationNoise(type: "station_noise")
        } else {
            audioHub.stopSimulationNoise()
        }
    }
}

public enum WhisperCoreError: Error, Sendable {
    case speechRecognitionDenied
    case microphoneDenied
    /// No `ggml-*.bin` model found in the app bundle (see README).
    case whisperModelNotFound
    /// iOS `whisper.xcframework` expects the Core ML encoder next to the GGML `.bin` (e.g. `ggml-tiny-encoder.mlmodelc`).
    case whisperCoreMLEncoderNotFound
}

extension WhisperCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .speechRecognitionDenied:
            return "Speech recognition permission is required for live captions."
        case .microphoneDenied:
            return "Microphone access is required to capture audio for captions."
        case .whisperModelNotFound:
            return "No Whisper model found. Add a ggml .bin file to the app target (e.g. models/ggml-base.bin)."
        case .whisperCoreMLEncoderNotFound:
            return "Core ML encoder bundle missing. The iOS build of whisper.cpp needs the matching ggml-*-encoder.mlmodelc folder next to your .bin (run ./scripts/download-whisper-model.sh — see README)."
        }
    }
}

public struct TranscriptionToken: Sendable {
    public let text: String
    public let confidence: Float
}

public enum TranscriptionMode: Sendable {
    case local
    case cloud
    case hybrid
}

/// Locales passed to Apple `SFSpeechRecognizer` (on-device availability varies by region and OS).
public enum SpeechRecognitionLocale: String, Sendable, CaseIterable, Codable {
    case englishUS = "en-US"
    case koreanKR = "ko-KR"

    public var locale: Locale { Locale(identifier: rawValue) }

    public var displayName: String {
        switch self {
        case .englishUS: "English (US)"
        case .koreanKR: "Korean (한국어)"
        }
    }

    /// ISO-639-1 language codes for `whisper.cpp` (`whisper_full_params.language`).
    var whisperLanguageCode: String {
        switch self {
        case .englishUS: "en"
        case .koreanKR: "ko"
        }
    }
}

public struct EngineConfig: Sendable {
    public var source: EngineSource
    public var enableDSP: Bool
    /// Used for Apple native recognition; Whisper.cpp / cloud paths may ignore this until wired.
    public var speechLocale: SpeechRecognitionLocale

    public init(
        source: EngineSource,
        enableDSP: Bool,
        speechLocale: SpeechRecognitionLocale = .englishUS
    ) {
        self.source = source
        self.enableDSP = enableDSP
        self.speechLocale = speechLocale
    }
}

public enum EngineSource: Sendable {
    case appleNative
    case whisperCpp
}