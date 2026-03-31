@preconcurrency import AVFoundation
import Accelerate

/// Ensures `CheckedContinuation` is resumed at most once (timeout vs utterance completion).
private final class SingleFlight: @unchecked Sendable {
    private var consumed = false
    private let lock = NSLock()

    func perform(_ action: () -> Void) {
        lock.lock()
        guard !consumed else { lock.unlock(); return }
        consumed = true
        lock.unlock()
        action()
    }
}

final class AudioProcessingHub: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let noisePlayer = AVAudioPlayerNode()

    /// Graph attach/connect runs once; `startStreaming` and `captureSingleUtterance` both need this before `installTap`.
    private var didAttachGraph = false

    /// Only one `installTap` may exist on `mixer` bus 0 at a time; installing twice triggers `nullptr == Tap()`.
    private var mixerTapInstalled = false

    /// Used to detect "engine.start() OK" with zero mixer tap callbacks (cold start); triggers a one-time restart.
    private let captionerTapBufferCountLock = NSLock()
    private var captionerTapBufferCount = 0

    private var noiseFloor: Float = 0.01

    // MARK: - REQ-2 / REQ-3: AGC + VAD hysteresis (per streaming / capture session)

    private enum AGCConstants {
        /// Target RMS (~−28 dBFS); adjust after field testing.
        static let targetRMS: Float = 0.042
        static let minLinearGain: Float = 0.35
        static let maxLinearGain: Float = 14.0
        /// Per-buffer smoothing toward ideal gain (higher = faster response).
        static let attackAlpha: Float = 0.38
        static let releaseAlpha: Float = 0.07
        static let limiterCeiling: Float = 0.97
    }

    private struct AGCState {
        var smoothedGain: Float = 1.0
    }

    private var agcState = AGCState()

    /// Raw VAD must be true this many buffers in a row before we treat speech as “on”.
    private var vadConsecutivePass = 0
    /// Raw VAD must be false this many buffers in a row before we treat speech as “off” (streaming gate only).
    private var vadConsecutiveFail = 0
    private var vadSpeechActive = false
    private let vadOpenConsecutive = 2
    private let vadCloseConsecutive = 4

    private func resetAudioProcessingState() {
        agcState = AGCState()
        vadConsecutivePass = 0
        vadConsecutiveFail = 0
        vadSpeechActive = false
        noiseFloor = 0.01
    }

    /// Multiple `audioLevelStream()` subscribers (e.g. SwiftUI re-running `onAppear`) must all receive levels; a single continuation would orphan earlier listeners.
    private let levelLock = NSLock()
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]

    private func broadcastLevel(_ value: Float) {
        levelLock.lock()
        let continuations = Array(levelContinuations.values)
        levelLock.unlock()
        for c in continuations {
            c.yield(value)
        }
    }

    /// Wait until mic access is resolved so `setActive` / `engine.start` see a live input on the first session.
    func ensureRecordPermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw AudioHubError.microphoneDenied
        case .undetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            if !granted {
                throw AudioHubError.microphoneDenied
            }
        @unknown default:
            throw AudioHubError.microphoneDenied
        }
    }

    func audioLevelStream() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            self.levelLock.lock()
            self.levelContinuations[id] = continuation
            self.levelLock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.levelLock.lock()
                self.levelContinuations[id] = nil
                self.levelLock.unlock()
            }
        }
    }

    func setupAudioSession(enableDSP: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        // REQ-1: Hardware-accelerated noise suppression
        try engine.inputNode.setVoiceProcessingEnabled(enableDSP)

        guard !didAttachGraph else { return }

        engine.attach(mixer)
        engine.attach(noisePlayer)

        // Setup noise player connection to mixer to simulate environmental noise (REQ-4.2)
        let noiseFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(noisePlayer, to: mixer, format: noiseFormat)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        engine.connect(engine.inputNode, to: mixer, format: inputFormat)

        // Complete the graph so the engine pulls audio; required before `installTap` on `mixer`.
        let mixerFormat = mixer.outputFormat(forBus: 0)
        engine.connect(mixer, to: engine.mainMixerNode, format: mixerFormat)
        engine.mainMixerNode.outputVolume = 0

        didAttachGraph = true
        WhisperDebugLog.audio.debug("setupAudioSession: graph attached (mixer+mic+mainMixer) DSP=\(enableDSP)")
    }

    /// Activates the audio session and builds the graph **before** Speech authorization so the mic prompt runs first and input routing is ready. Call at the start of live captioning.
    func prepareSessionForLiveCaptioning(enableDSP: Bool) throws {
        try setupAudioSession(enableDSP: enableDSP)
        WhisperDebugLog.audio.debug("prepareSessionForLiveCaptioning: session + graph ready (mic permission may have been prompted)")
    }

    private func removeMixerTapIfNeeded() {
        if engine.isRunning {
            engine.stop()
        }
        guard mixerTapInstalled else { return }
        mixer.removeTap(onBus: 0)
        mixerTapInstalled = false
    }
    
    /// - Parameter gateWithVAD: If `true`, only buffers that pass VAD are yielded (saves work for chunked engines).
    ///   If `false`, every tap buffer is yielded — use for **live** Apple Speech so the recognizer receives continuous audio (Speech does its own endpointing).
    /// - Parameter pipeline: **original** (v1.0) skips AGC/hysteresis; **v1.1** applies envelope AGC + VAD hysteresis before yield.
    func startStreaming(
        enableDSP: Bool = true,
        gateWithVAD: Bool = true,
        pipeline: AudioProcessingPipeline = .v1_1
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        return AsyncThrowingStream { continuation in
            do {
                try self.setupAudioSession(enableDSP: enableDSP)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            self.removeMixerTapIfNeeded()

            self.captionerTapBufferCountLock.lock()
            self.captionerTapBufferCount = 0
            self.captionerTapBufferCountLock.unlock()

            let format = mixer.outputFormat(forBus: 0)
            WhisperDebugLog.audio.debug(
                "Captioner startStreaming: sampleRate=\(format.sampleRate) ch=\(format.channelCount) tapBuffer=4096 gateWithVAD=\(gateWithVAD) pipeline=\(pipeline.rawValue)"
            )

            final class NoBufferRetryBox: @unchecked Sendable {
                var work: DispatchWorkItem?
            }
            let noBufferRetryBox = NoBufferRetryBox()

            func installCaptionerTapAndStartEngine(scheduleSilentStartRecovery: Bool) {
                self.resetAudioProcessingState()
                var streamLog = StreamingCaptionerLogState()
                self.mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                    self.captionerTapBufferCountLock.lock()
                    self.captionerTapBufferCount += 1
                    self.captionerTapBufferCountLock.unlock()
                    noBufferRetryBox.work?.cancel()

                    let vad = self.evaluateVAD(buffer)
                    streamLog.bufferCount += 1

                    switch pipeline {
                    case .v1_1:
                        let passedHyst = self.updateVADHysteresis(rawPassed: vad.passed)
                        self.processBufferForOutput(buffer)
                        if gateWithVAD {
                            if passedHyst {
                                WhisperDebugLog.audio.debug(
                                    "Captioner tap #\(streamLog.bufferCount) VAD+hyst PASS rms=\(String(format: "%.5f", vad.rms)) zcr=\(String(format: "%.4f", vad.zcr)) noiseFloor=\(String(format: "%.5f", vad.noiseFloor)) -> yield to transcribe"
                                )
                                continuation.yield(buffer)
                            } else {
                                streamLog.maybeLogReject(vad: vad, bufferIndex: streamLog.bufferCount)
                            }
                        } else {
                            if streamLog.bufferCount == 1 || streamLog.bufferCount % 120 == 0 {
                                WhisperDebugLog.audio.debug(
                                    "Captioner tap #\(streamLog.bufferCount) pass-through rms=\(String(format: "%.5f", vad.rms)) (VAD off for live Speech)"
                                )
                            }
                            continuation.yield(buffer)
                        }
                    case .original:
                        if gateWithVAD {
                            if vad.passed {
                                WhisperDebugLog.audio.debug(
                                    "Captioner tap #\(streamLog.bufferCount) VAD PASS rms=\(String(format: "%.5f", vad.rms)) zcr=\(String(format: "%.4f", vad.zcr)) noiseFloor=\(String(format: "%.5f", vad.noiseFloor)) -> yield to transcribe"
                                )
                                continuation.yield(buffer)
                            } else {
                                streamLog.maybeLogReject(vad: vad, bufferIndex: streamLog.bufferCount)
                            }
                        } else {
                            if streamLog.bufferCount == 1 || streamLog.bufferCount % 120 == 0 {
                                WhisperDebugLog.audio.debug(
                                    "Captioner tap #\(streamLog.bufferCount) pass-through rms=\(String(format: "%.5f", vad.rms)) (VAD off for live Speech)"
                                )
                            }
                            continuation.yield(buffer)
                        }
                    }
                }
                self.mixerTapInstalled = true

                do {
                    self.engine.prepare()
                    try self.engine.start()
                    WhisperDebugLog.audio.debug("Captioner engine.prepare()+start() OK")
                } catch {
                    WhisperDebugLog.audio.error("Captioner engine.start() failed: \(String(describing: error))")
                    self.removeMixerTapIfNeeded()
                    continuation.finish(throwing: error)
                    return
                }

                guard scheduleSilentStartRecovery else { return }

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.captionerTapBufferCountLock.lock()
                    let n = self.captionerTapBufferCount
                    self.captionerTapBufferCountLock.unlock()
                    guard n == 0 else { return }
                    WhisperDebugLog.audio.debug("Captioner: no mixer tap buffers after start — stopping and restarting engine once")
                    self.removeMixerTapIfNeeded()
                    self.captionerTapBufferCountLock.lock()
                    self.captionerTapBufferCount = 0
                    self.captionerTapBufferCountLock.unlock()
                    installCaptionerTapAndStartEngine(scheduleSilentStartRecovery: false)
                }
                noBufferRetryBox.work = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
            }

            installCaptionerTapAndStartEngine(scheduleSilentStartRecovery: true)

            continuation.onTermination = { [weak self] _ in
                noBufferRetryBox.work?.cancel()
                WhisperDebugLog.audio.debug("Captioner stream terminated (tap removed)")
                self?.removeMixerTapIfNeeded()
            }
        }
    }
    
    func captureSingleUtterance(enableDSP: Bool = true, pipeline: AudioProcessingPipeline = .v1_1) async throws -> AVAudioPCMBuffer {
        try await ensureRecordPermission()
        try setupAudioSession(enableDSP: enableDSP)
        
        return try await withCheckedThrowingContinuation { continuation in
            let endOnce = SingleFlight()

            func finishOnMain(result: AVAudioPCMBuffer?, error: Error?) {
                DispatchQueue.main.async { [self] in
                    endOnce.perform {
                        self.removeMixerTapIfNeeded()
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let result = result {
                            continuation.resume(returning: result)
                        }
                    }
                }
            }

            let format = mixer.outputFormat(forBus: 0)
            // REQ-10: Discrete utterances are capped at 30 seconds to prevent memory overflow
            let maxFrames = AVAudioFrameCount(format.sampleRate * 30)
            
            guard let accumulatedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
                continuation.resume(throwing: AudioHubError.bufferCreationFailed)
                return
            }
            
            var speechDetected = false
            var silenceFrames: Int = 0
            let silenceThresholdFrames = Int(format.sampleRate * 1.5) // 1.5s of silence triggers completion
            var isFinished = false
            
            // REQ-10.1: Initial timeout if no speech is detected within 10 seconds
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard !Task.isCancelled && !speechDetected && !isFinished else { return }
                
                isFinished = true
                finishOnMain(result: nil, error: AudioHubError.timeout)
            }

            self.removeMixerTapIfNeeded()
            self.resetAudioProcessingState()

            mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self = self, !isFinished else { return }

                let vad = self.evaluateVAD(buffer)

                switch pipeline {
                case .v1_1:
                    let hystOpen = self.updateVADHysteresis(rawPassed: vad.passed)
                    if hystOpen {
                        if !speechDetected {
                            timeoutTask.cancel() // Speech started, stop the "no-speech" timer
                        }
                        speechDetected = true
                        silenceFrames = 0
                    } else if speechDetected {
                        if !vad.passed {
                            silenceFrames += Int(buffer.frameLength)
                        } else {
                            silenceFrames = 0
                        }
                    }
                    if speechDetected {
                        self.processBufferForOutput(buffer)
                        self.append(buffer: buffer, to: accumulatedBuffer)
                    }
                case .original:
                    if vad.passed {
                        if !speechDetected {
                            timeoutTask.cancel()
                        }
                        speechDetected = true
                        silenceFrames = 0
                    } else if speechDetected {
                        silenceFrames += Int(buffer.frameLength)
                    }
                    if speechDetected {
                        self.applyLegacyAutoGain(to: buffer)
                        self.append(buffer: buffer, to: accumulatedBuffer)
                    }
                }
                
                // Termination: Check for silence timeout or reaching 30s capacity
                if (speechDetected && silenceFrames >= silenceThresholdFrames) || accumulatedBuffer.frameLength >= accumulatedBuffer.frameCapacity {
                    isFinished = true
                    finishOnMain(result: accumulatedBuffer, error: nil)
                }
            }
            self.mixerTapInstalled = true

            do {
                self.engine.prepare()
                try self.engine.start()
            } catch {
                isFinished = true
                timeoutTask.cancel()
                finishOnMain(result: nil, error: error)
            }
        }
    }
    
    private struct VADResult {
        let passed: Bool
        let rms: Float
        let zcr: Float
        let noiseFloor: Float
        let hasEnergyBurst: Bool
        let isNotNoiseClatter: Bool
    }

    private struct StreamingCaptionerLogState {
        var bufferCount = 0
        private var lastRejectLogTime: CFAbsoluteTime = 0

        mutating func maybeLogReject(vad: VADResult, bufferIndex: Int) {
            let now = CFAbsoluteTimeGetCurrent()
            let shouldLog = bufferIndex <= 8 || now - lastRejectLogTime >= 0.35
            guard shouldLog else { return }
            lastRejectLogTime = now
            WhisperDebugLog.audio.debug(
                "Captioner tap #\(bufferIndex) VAD reject rms=\(String(format: "%.5f", vad.rms)) zcr=\(String(format: "%.4f", vad.zcr)) noiseFloor=\(String(format: "%.5f", vad.noiseFloor)) hasEnergyBurst=\(vad.hasEnergyBurst) lowZcr=\(vad.isNotNoiseClatter) (pass needs both true)"
            )
        }
    }

    /// REQ-3: VAD; updates level meter and adaptive noise floor.
    private func evaluateVAD(_ buffer: AVAudioPCMBuffer) -> VADResult {
        guard let channelData = buffer.floatChannelData?[0] else {
            return VADResult(passed: false, rms: 0, zcr: 0, noiseFloor: noiseFloor, hasEnergyBurst: false, isNotNoiseClatter: false)
        }
        let frameLength = vDSP_Length(buffer.frameLength)

        var rms: Float = 0.0
        vDSP_rmsqv(channelData, 1, &rms, frameLength)

        let db = 20 * log10(max(rms, 0.000001))
        let normalizedLevel = max(0.0, (db + 60.0) / 60.0)
        broadcastLevel(normalizedLevel)

        let fl = Int(frameLength)
        var crossings = 0
        if fl > 1 {
            for i in 1..<fl where channelData[i] * channelData[i - 1] < 0 {
                crossings += 1
            }
        }
        let zcr = Float(crossings) / Float(max(fl, 1))

        if rms < noiseFloor * 1.5 {
            noiseFloor = (noiseFloor * 0.99) + (rms * 0.01)
        }

        let hasEnergyBurst = rms > max(0.015, noiseFloor * 2.5)
        let isNotNoiseClatter = zcr < 0.18
        let passed = hasEnergyBurst && isNotNoiseClatter

        return VADResult(
            passed: passed,
            rms: rms,
            zcr: zcr,
            noiseFloor: noiseFloor,
            hasEnergyBurst: hasEnergyBurst,
            isNotNoiseClatter: isNotNoiseClatter
        )
    }

    /// Hysteresis on raw VAD: reduces flutter; `vadSpeechActive` is the smoothed speech gate.
    private func updateVADHysteresis(rawPassed: Bool) -> Bool {
        if rawPassed {
            vadConsecutiveFail = 0
            vadConsecutivePass += 1
            if vadConsecutivePass >= vadOpenConsecutive {
                vadSpeechActive = true
            }
        } else {
            vadConsecutivePass = 0
            vadConsecutiveFail += 1
            if vadConsecutiveFail >= vadCloseConsecutive {
                vadSpeechActive = false
            }
        }
        return vadSpeechActive
    }

    /// REQ-2: Per-buffer DC removal, envelope AGC toward target RMS, soft limiter (in-place).
    private func processBufferForOutput(_ buffer: AVAudioPCMBuffer) {
        let chCount = Int(buffer.format.channelCount)
        guard chCount >= 1, let channels = buffer.floatChannelData else { return }
        let n = vDSP_Length(buffer.frameLength)

        for c in 0..<chCount {
            removeDCOffset(samples: channels[c], count: n)
        }

        var rms: Float = 0
        vDSP_rmsqv(channels[0], 1, &rms, n)
        let ideal = AGCConstants.targetRMS / max(rms, 1e-8)
        let clamped = min(max(ideal, AGCConstants.minLinearGain), AGCConstants.maxLinearGain)
        let alpha = clamped > agcState.smoothedGain ? AGCConstants.attackAlpha : AGCConstants.releaseAlpha
        agcState.smoothedGain += (clamped - agcState.smoothedGain) * alpha

        var g = agcState.smoothedGain
        for c in 0..<chCount {
            vDSP_vsmul(channels[c], 1, &g, channels[c], 1, n)
        }

        let ceiling = AGCConstants.limiterCeiling
        let frameCount = Int(n)
        for c in 0..<chCount {
            let ptr = channels[c]
            for i in 0..<frameCount {
                let s = ptr[i]
                if s > ceiling {
                    ptr[i] = ceiling
                } else if s < -ceiling {
                    ptr[i] = -ceiling
                }
            }
        }
    }

    private func removeDCOffset(samples: UnsafeMutablePointer<Float>, count: vDSP_Length) {
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, count)
        var neg = -mean
        vDSP_vsadd(samples, 1, &neg, samples, 1, count)
    }

    /// v1.0 pipeline: simple ×2 when peak is below 0.1 on channel 0 (Messenger / single utterance only).
    private func applyLegacyAutoGain(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = vDSP_Length(buffer.frameLength)
        var maxAmplitude: Float = 0
        vDSP_maxv(channelData, 1, &maxAmplitude, frameLength)
        if maxAmplitude < 0.1 && maxAmplitude > 0 {
            var multiplier: Float = 2.0
            vDSP_vsmul(channelData, 1, &multiplier, channelData, 1, frameLength)
        }
    }

    private func append(buffer: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        let frameCount = buffer.frameLength
        let capacity = destination.frameCapacity
        let currentLength = destination.frameLength
        
        guard currentLength + frameCount <= capacity else { return }
        
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            let src = buffer.floatChannelData![channel]
            let dst = destination.floatChannelData![channel].advanced(by: Int(currentLength))
            memcpy(dst, src, Int(frameCount) * MemoryLayout<Float>.size)
        }
        destination.frameLength = currentLength + frameCount
    }

    func playSimulationNoise(type: String) {
        guard let url = Bundle.main.url(forResource: type, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return }
        
        noisePlayer.scheduleFile(file, at: nil, completionHandler: nil)
        if !engine.isRunning { try? engine.start() }
        noisePlayer.play()
    }
    
    func stopSimulationNoise() {
        noisePlayer.stop()
    }
}

enum AudioHubError: Error {
    case bufferCreationFailed
    case timeout
    case microphoneDenied
}