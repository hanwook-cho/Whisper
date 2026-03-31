import SwiftUI
import WhisperCore

struct ContentView: View {
    @State private var transcription: String = "Tap 'Start' to begin..."
    @State private var isRecording = false
    @State private var selectedEngine: EngineSource = .appleNative
    @State private var transcriptionMode: TranscriptionMode = .local
    @State private var dspEnabled = true
    @State private var speechLocale: SpeechRecognitionLocale = .englishUS
    @State private var showSettings = false
    @State private var audioLevel: Float = 0.0
    @State private var captionTask: Task<Void, Never>?

    var body: some View {
        TabView {
            NavigationStack {
                VStack {
                    ScrollView {
                        Text(transcription)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.05))

                    // Volume Meter (REQ-3 Visual Validation)
                    HStack(spacing: 4) {
                        ForEach(0..<12) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(audioLevel * 12 > Float(index) ? Color.green : Color.gray.opacity(0.2))
                                .frame(width: 15, height: 30)
                        }
                    }
                    .padding(.vertical)
                    .animation(.linear(duration: 0.1), value: audioLevel)

                    Button(isRecording ? "Stop Captioning" : "Start Live Captions") {
                        toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
                .navigationTitle("Captioner")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .tabItem { Label("Captioner", systemImage: "captions.bubble") }

            NavigationStack {
                VStack {
                    Spacer()
                    Text("Hold to speak, release to send.")
                        .foregroundColor(.secondary)

                    Circle()
                        .fill(Color.blue)
                        .frame(width: 80, height: 80)
                        .overlay(Image(systemName: "mic.fill").foregroundColor(.white))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in if !isRecording { startMessaging() } }
                                .onEnded { _ in stopMessaging() }
                        )
                        .padding(40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Messenger")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .tabItem { Label("Messenger", systemImage: "message") }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: $selectedEngine, mode: $transcriptionMode, dsp: $dspEnabled, speechLocale: $speechLocale)
        }
        .onAppear {
            Task {
                try? await WhisperCore.shared.ensureMicrophonePermission()
                try? await WhisperCore.shared.ensureSpeechAuthorization()
            }
            Task {
                for await level in WhisperCore.shared.audioLevelStream() {
                    await MainActor.run { self.audioLevel = level }
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            captionTask?.cancel()
            captionTask = nil
            isRecording = false
            return
        }
        isRecording = true
        transcription = ""
        let config = EngineConfig(source: selectedEngine, enableDSP: dspEnabled, speechLocale: speechLocale)
        captionTask = Task { @MainActor in
            do {
                for try await token in WhisperCore.shared.startLiveCaptioning(config: config) {
                    if Task.isCancelled { break }
                    // Apple partial results are full cumulative text; Whisper chunks are discrete phrases.
                    transcription = token.text
                }
            } catch {
                transcription = "Error: \(error.localizedDescription)"
            }
            isRecording = false
            captionTask = nil
        }
    }

    private func startMessaging() {
        isRecording = true
        // Start recording logic
    }

    private func stopMessaging() {
        isRecording = false
        Task {
            let config = EngineConfig(source: selectedEngine, enableDSP: dspEnabled, speechLocale: speechLocale)
            let result = try? await WhisperCore.shared.transcribeOnce(mode: transcriptionMode, config: config)
            transcription = result?.text ?? "No speech detected."
        }
    }
}
