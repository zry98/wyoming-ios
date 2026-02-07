import AVFoundation
import SwiftUI

/// TTS voice selection view with speech parameter controls.
struct TTSVoicesListView: View {
  @ObservedObject var settingsManager: SettingsManager
  @State private var voices: [Voice] = []
  @State private var sortedVoices: [Voice] = []
  private let previewSynthesizer = AVSpeechSynthesizer()

  var body: some View {
    List {
      Section("Speech Parameters") {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Rate")
            Spacer()
            Text(String(format: "%.1f", settingsManager.defaultTTSRate))
              .foregroundColor(.secondary)
          }
          HStack {
            Image(systemName: "tortoise")
              .foregroundColor(.secondary)
            Slider(
              value: $settingsManager.defaultTTSRate,
              in: Float(AVSpeechUtteranceMinimumSpeechRate)...Float(AVSpeechUtteranceMaximumSpeechRate), step: 0.05)
            Image(systemName: "hare")
              .foregroundColor(.secondary)
          }
        }
        .disabled(settingsManager.defaultTTSPrefersAssistiveTechnologySettings)
        .opacity(settingsManager.defaultTTSPrefersAssistiveTechnologySettings ? 0.5 : 1.0)

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Pitch")
            Spacer()
            Text(String(format: "%.1f", settingsManager.defaultTTSPitch))
              .foregroundColor(.secondary)
          }
          HStack {
            Image(systemName: "waveform")
              .foregroundColor(.secondary)
            Slider(value: $settingsManager.defaultTTSPitch, in: 0.5...2.0, step: 0.1)
            Image(systemName: "waveform.path")
              .foregroundColor(.secondary)
          }
        }
        .disabled(settingsManager.defaultTTSPrefersAssistiveTechnologySettings)
        .opacity(settingsManager.defaultTTSPrefersAssistiveTechnologySettings ? 0.5 : 1.0)

        Stepper(value: $settingsManager.defaultTTSPause, in: 0.0...2.0, step: 0.1) {
          HStack {
            Text("Sentence Pause")
            Spacer()
            Text(String(format: "%.1fs", settingsManager.defaultTTSPause))
              .foregroundColor(.secondary)
          }
        }
        .disabled(settingsManager.defaultTTSPrefersAssistiveTechnologySettings)
        .opacity(settingsManager.defaultTTSPrefersAssistiveTechnologySettings ? 0.5 : 1.0)

        Toggle(
          "Prefer Assistive Technology Settings",
          isOn: $settingsManager.defaultTTSPrefersAssistiveTechnologySettings)

        Button(action: {
          settingsManager.resetTTSVoiceSettings()
        }) {
          HStack {
            Spacer()
            Text("Reset Voice Settings")
              .fontWeight(.semibold)
              .foregroundColor(.red)
            Spacer()
          }
        }
      }

      Section("Tap a voice to preview and set it as default") {
        ForEach(sortedVoices, id: \.id) { voice in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              let targetLocale = Locale(identifier: voice.language)
              let languageName = targetLocale.localizedString(forIdentifier: voice.language) ?? voice.language
              Text("\(languageName) • \(voice.name)")
              Text(voice.id)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if settingsManager.defaultTTSVoice == voice.id {
              Image(systemName: "checkmark")
                .foregroundColor(.blue)
            }
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .onTapGesture {
            if settingsManager.defaultTTSVoice == voice.id {
              settingsManager.defaultTTSVoice = ""
            } else {
              settingsManager.defaultTTSVoice = voice.id
            }

            playVoiceSample(voice)
          }
        }
      }
    }
    .navigationTitle("TTS Voices")
    .inlineNavigationBarTitle()
    .onAppear {
      voices = TTSService.getAvailableVoices()
      updateSortedVoices()
    }
    .onChange(of: voices) { _ in
      updateSortedVoices()
    }
  }

  /// Sorts voices by language first, then by name within each language
  private func updateSortedVoices() {
    sortedVoices = voices.sorted { v1, v2 in
      if v1.language != v2.language {
        return v1.language.localizedCaseInsensitiveCompare(v2.language) == .orderedAscending
      }
      return v1.name.localizedCaseInsensitiveCompare(v2.name) == .orderedAscending
    }
  }

  /// Plays a voice sample using the language name as text.
  private func playVoiceSample(_ voice: Voice) {
    // stop any currently playing speech
    if previewSynthesizer.isSpeaking {
      previewSynthesizer.stopSpeaking(at: .immediate)
    }

    let targetLocale = Locale(identifier: voice.language)
    let languageName = targetLocale.localizedString(forIdentifier: voice.language) ?? voice.language

    let utterance = AVSpeechUtterance(string: languageName)
    if let avVoice = AVSpeechSynthesisVoice(identifier: voice.id) {
      utterance.voice = avVoice
    }

    utterance.prefersAssistiveTechnologySettings = settingsManager.defaultTTSPrefersAssistiveTechnologySettings
    utterance.rate = Float(settingsManager.defaultTTSRate)
    utterance.pitchMultiplier = Float(settingsManager.defaultTTSPitch)
    utterance.postUtteranceDelay = TimeInterval(settingsManager.defaultTTSPause)

    previewSynthesizer.speak(utterance)
  }
}
