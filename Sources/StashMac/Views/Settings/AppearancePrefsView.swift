import SwiftUI
import AVFoundation

/// Appearance preferences pane: hosts the System / Dark / Light theme
/// picker and the Cooking Assistant spoken-voice settings.
struct AppearancePrefsView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .system
    @AppStorage("cookingVoiceID") private var voiceID: String = "default"
    @AppStorage("cookingAutoSpeak") private var autoSpeak: Bool = false
    @State private var synthesizer = AVSpeechSynthesizer()

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Theme") {
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }

            Section("Cooking Assistant Voice") {
                HStack {
                    Picker("Voice", selection: $voiceID) {
                        Text("System Default (or Premium/Enhanced)").tag("default")
                        Divider()
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voiceQualityString(for: voice)))").tag(voice.identifier)
                        }
                    }

                    Button {
                        testVoice(voiceID: voiceID)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(Color.accentColor)
                    .help("Play a sample of the selected voice")
                }

                Toggle("Automatically speak steps in Cooking Assistant", isOn: $autoSpeak)

                Text("Select the voice used by the Cooking Assistant when reading recipe steps aloud. For high-quality voices like Alex or Ava, download them first in System Settings -> Accessibility -> Spoken Content.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted(by: { $0.name < $1.name })
    }

    private func voiceQualityString(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private func testVoice(voiceID: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: "Step 1. Preheat the oven and prepare your ingredients.")
        if voiceID != "default", let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.quality == .premium && $0.language == "en-US" }) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.quality == .enhanced && $0.language == "en-US" }) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
}
