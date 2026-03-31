import Foundation
import AVFoundation

/// Generic REST wrapper for cloud-based transcription (REQ-6).
final class CloudEngine: TranscriptionEngine {
    required init() {}
    
    func transcribe(buffer: AVAudioPCMBuffer, config: EngineConfig) async throws -> TranscriptionToken {
        _ = config
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer YOUR_API_KEY", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Convert PCM Buffer to WAV data and wrap in multipart form
        let audioData = wavData(from: buffer)
        let body = createMultipartBody(binaryData: audioData, boundary: boundary, fileName: "audio.wav")
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        // Parse the typical Whisper JSON response: { "text": "..." }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return TranscriptionToken(text: text, confidence: 0.9)
        }
        
        return TranscriptionToken(text: "Cloud transcription failed to parse.", confidence: 0.0)
    }
    
    private func createMultipartBody(binaryData: Data, boundary: String, fileName: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        
        // Form field: model
        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)")
        body.append("whisper-1\(lineBreak)")
        
        // Form field: file
        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: audio/wav\(lineBreak)\(lineBreak)")
        body.append(binaryData)
        body.append(lineBreak)
        
        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
    
    /// Wraps AVAudioPCMBuffer in a standard 44-byte WAV header.
    private func wavData(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = UInt32(buffer.frameLength)
        let channels = UInt16(buffer.format.channelCount)
        let sampleRate = UInt32(buffer.format.sampleRate)
        let bitsPerSample = UInt16(16) // Converting to 16-bit PCM for wide compatibility
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = frameCount * UInt32(blockAlign)
        
        var header = Data()
        header.append(Data("RIFF".utf8))
        header.append(withUnsafeBytes(of: dataSize + 36) { Data($0) })
        header.append(Data("WAVE".utf8))
        header.append(Data("fmt ".utf8))
        header.append(withUnsafeBytes(of: UInt32(16)) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1)) { Data($0) }) // PCM format
        header.append(withUnsafeBytes(of: channels) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample) { Data($0) })
        header.append(Data("data".utf8))
        header.append(withUnsafeBytes(of: dataSize) { Data($0) })
        
        // Convert Float32 samples to Int16
        var audioData = Data()
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let sample = max(-1, min(1, channelData[i]))
                let intSample = Int16(sample < 0 ? sample * 32768 : sample * 32767)
                audioData.append(withUnsafeBytes(of: intSample) { Data($0) })
            }
        }
        
        return header + audioData
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}