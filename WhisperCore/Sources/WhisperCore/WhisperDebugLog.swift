import Foundation
import os

/// Unified subsystem for Console.app: filter by subsystem `com.whisper.WhisperCore` or category `AudioHub` / `WhisperCore` / `Engine`.
enum WhisperDebugLog {
    static let subsystem = "com.whisper.WhisperCore"

    static let audio = Logger(subsystem: subsystem, category: "AudioHub")
    static let facade = Logger(subsystem: subsystem, category: "WhisperCore")
    static let engine = Logger(subsystem: subsystem, category: "Engine")
}
