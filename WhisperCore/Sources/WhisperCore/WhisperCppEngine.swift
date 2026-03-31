import Foundation
import AVFoundation
import Accelerate
import whisper

/// Local inference using whisper.cpp (linked via `Vendor/whisper.xcframework`).
final class WhisperCppEngine: TranscriptionEngine {
    required init() {}

    func transcribe(buffer: AVAudioPCMBuffer, config: EngineConfig) async throws -> TranscriptionToken {
        let samples = try WhisperCppAudio.resampleTo16kMonoFloat(buffer)
        guard !samples.isEmpty else {
            return TranscriptionToken(text: "", confidence: 0)
        }
        let text = try await WhisperCppRunner.shared.transcribe(
            samples: samples,
            languageCode: config.speechLocale.whisperLanguageCode
        )
        return TranscriptionToken(text: text, confidence: 0.88)
    }
}

// MARK: - Audio

private enum WhisperCppAudio {
    static func resampleTo16kMonoFloat(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let srcFormat = buffer.format
        guard
            let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(WHISPER_SAMPLE_RATE),
                channels: 1,
                interleaved: false
            )
        else {
            throw WhisperCppEngineError.audioConversionFailed
        }

        if abs(srcFormat.sampleRate - dstFormat.sampleRate) < 0.5,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32,
           let ch = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw WhisperCppEngineError.audioConversionFailed
        }

        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
            throw WhisperCppEngineError.audioConversionFailed
        }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var convError: NSError?
        converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
        if let convError { throw convError }

        guard let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}

// MARK: - whisper.cpp runner (serialized; one context)

private actor WhisperCppRunner {
    static let shared = WhisperCppRunner()

    private var context: OpaquePointer?

    func transcribe(samples: [Float], languageCode: String) throws -> String {
        try ensureContext()
        guard let context else {
            throw WhisperCoreError.whisperModelNotFound
        }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.n_threads = Int32(maxThreads)

        languageCode.withCString { lang in
            params.language = lang
        }

        whisper_reset_timings(context)

        let code = samples.withUnsafeBufferPointer { buf in
            whisper_full(context, params, buf.baseAddress, Int32(samples.count))
        }
        guard code == 0 else {
            return ""
        }

        var transcription = ""
        let n = whisper_full_n_segments(context)
        for i in 0..<n {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureContext() throws {
        if context != nil { return }

        let url = try Self.materializedModelURL()

        // Prefer GPU on device; fall back to CPU if init fails (Metal auxiliary fopen / older chips).
        var cparams = whisper_context_default_params()
#if targetEnvironment(simulator)
        cparams.use_gpu = false
#else
        cparams.flash_attn = true
#endif
        if let ctx = whisper_init_from_file_with_params(url.path, cparams) {
            context = ctx
            WhisperDebugLog.engine.debug("WhisperCpp: loaded model from \(url.path) gpu=\(cparams.use_gpu)")
            return
        }

        WhisperDebugLog.engine.debug("WhisperCpp: init failed with GPU path; retrying CPU-only")
        var cpu = whisper_context_default_params()
        cpu.use_gpu = false
        cpu.flash_attn = false
        guard let ctxCPU = whisper_init_from_file_with_params(url.path, cpu) else {
            throw WhisperCoreError.whisperModelNotFound
        }
        context = ctxCPU
        WhisperDebugLog.engine.debug("WhisperCpp: loaded model CPU-only from \(url.path)")
    }

    /// Resolves a GGML file in the app bundle, then copies it to Application Support so mmap/open is reliable on device.
    /// The official iOS `whisper.xcframework` is built with Core ML: it also requires `ggml-<stem>-encoder.mlmodelc`
    /// in the **same directory** as the `.bin` (derived from the bin filename). See whisper.cpp `whisper_get_coreml_path_encoder`.
    private static func materializedModelURL() throws -> URL {
        guard let bundleURL = bundledModelURL() else {
            throw WhisperCoreError.whisperModelNotFound
        }

        let fm = FileManager.default
        let destDir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WhisperCpp", isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let dest = destDir.appendingPathComponent(bundleURL.lastPathComponent)

        if !fm.fileExists(atPath: dest.path) {
            try fm.copyItem(at: bundleURL, to: dest)
        } else if shouldRefreshFileCopy(bundle: bundleURL, deployed: dest) {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: bundleURL, to: dest)
        }

        guard fm.isReadableFile(atPath: dest.path) else {
            throw WhisperCoreError.whisperModelNotFound
        }

        guard let encoderSrc = bundledCoreMLEncoderURL(matchingBinURL: bundleURL) else {
            throw WhisperCoreError.whisperCoreMLEncoderNotFound
        }
        let encoderDest = destDir.appendingPathComponent(encoderSrc.lastPathComponent)
        if !fm.fileExists(atPath: encoderDest.path) {
            try fm.copyItem(at: encoderSrc, to: encoderDest)
            WhisperDebugLog.engine.debug("WhisperCpp: deployed Core ML encoder to \(encoderDest.path)")
        } else if shouldRefreshDirectoryCopy(bundle: encoderSrc, deployed: encoderDest) {
            try? fm.removeItem(at: encoderDest)
            try fm.copyItem(at: encoderSrc, to: encoderDest)
            WhisperDebugLog.engine.debug("WhisperCpp: refreshed Core ML encoder at \(encoderDest.path)")
        }

        return dest
    }

    /// e.g. ggml-tiny.bin → ggml-tiny-encoder.mlmodelc ; ggml-base.en.bin → ggml-base.en-encoder.mlmodelc
    private static func coreMLEncoderFileName(forBinURL binURL: URL) -> String {
        let stem = binURL.deletingPathExtension().lastPathComponent
        return "\(stem)-encoder.mlmodelc"
    }

    private static func bundledCoreMLEncoderURL(matchingBinURL binURL: URL) -> URL? {
        let encoderStem = binURL.deletingPathExtension().lastPathComponent + "-encoder"
        if let u = Bundle.main.url(forResource: encoderStem, withExtension: "mlmodelc", subdirectory: "models") {
            return u
        }
        if let u = Bundle.main.url(forResource: encoderStem, withExtension: "mlmodelc") {
            return u
        }
        if let inModels = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: "models") {
            let name = coreMLEncoderFileName(forBinURL: binURL)
            if let match = inModels.first(where: { $0.lastPathComponent == name }) {
                return match
            }
        }
        return nil
    }

    private static func shouldRefreshDirectoryCopy(bundle: URL, deployed: URL) -> Bool {
        let b = bundleDirectoryAllocatedSize(bundle)
        let d = bundleDirectoryAllocatedSize(deployed)
        return b > 0 && b != d
    }

    private static func bundleDirectoryAllocatedSize(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }
        return total
    }

    private static func shouldRefreshFileCopy(bundle: URL, deployed: URL) -> Bool {
        guard let b = try? FileManager.default.attributesOfItem(atPath: bundle.path)[.size] as? UInt64,
              let d = try? FileManager.default.attributesOfItem(atPath: deployed.path)[.size] as? UInt64 else {
            return false
        }
        return b != d
    }

    /// Prefer `models/*.bin` in the bundle (Xcode folder refs); fall back to `forResource`.
    private static func bundledModelURL() -> URL? {
        let preferredBaseNames = ["ggml-tiny", "ggml-base", "ggml-base.en", "ggml-small", "ggml-medium"]

        if let inModels = Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: "models") {
            for base in preferredBaseNames {
                if let match = inModels.first(where: {
                    $0.deletingPathExtension().lastPathComponent == base
                }) {
                    return match
                }
            }
        }

        if let rootBins = Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: nil) {
            for base in preferredBaseNames {
                if let match = rootBins.first(where: {
                    $0.deletingPathExtension().lastPathComponent == base
                }) {
                    return match
                }
            }
        }

        let candidates: [(String, String, String?)] = [
            ("ggml-tiny", "bin", "models"),
            ("ggml-base", "bin", "models"),
            ("ggml-base.en", "bin", "models"),
            ("ggml-small", "bin", "models"),
            ("ggml-tiny", "bin", nil),
            ("ggml-base", "bin", nil),
            ("ggml-base.en", "bin", nil),
        ]
        for (name, ext, sub) in candidates {
            if let sub {
                if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub) { return u }
            } else {
                if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
            }
        }
        return nil
    }

}

private enum WhisperCppEngineError: Error {
    case audioConversionFailed
}
