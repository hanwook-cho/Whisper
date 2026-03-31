import SwiftUI
import WhisperCore

struct SettingsView: View {
    @Binding var engine: EngineSource
    @Binding var mode: TranscriptionMode
    @Binding var dsp: Bool
    @Binding var speechLocale: SpeechRecognitionLocale
    @State private var isSimulatingNoise = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Engine Settings") {
                    Picker("Source", selection: $engine) {
                        Text("Apple Native").tag(EngineSource.appleNative)
                        Text("Whisper.cpp").tag(EngineSource.whisperCpp)
                    }
                    Picker("Recognition language", selection: $speechLocale) {
                        ForEach(SpeechRecognitionLocale.allCases, id: \.self) { locale in
                            Text(locale.displayName).tag(locale)
                        }
                    }
                    .disabled(engine != .appleNative)
                    Picker("Mode", selection: $mode) {
                        Text("Local Only").tag(TranscriptionMode.local)
                        Text("Cloud Only").tag(TranscriptionMode.cloud)
                        Text("Hybrid").tag(TranscriptionMode.hybrid)
                    }
                }
                
                Section("DSP & Simulation") {
                    Toggle("Noise Suppression (REQ-1)", isOn: $dsp)
                    Button(isSimulatingNoise ? "Stop Simulation" : "Simulate 'Station' Noise") {
                        // Inject high-frequency clatter into the audio stream
                        isSimulatingNoise.toggle()
                        WhisperCore.shared.simulateNoise(enabled: isSimulatingNoise)
                    }
                    .foregroundColor(isSimulatingNoise ? .blue : .red)
                }
            }
            .navigationTitle("Module Settings")
            .toolbar {
                EditButton() // Placeholder for close
            }
        }
    }
}