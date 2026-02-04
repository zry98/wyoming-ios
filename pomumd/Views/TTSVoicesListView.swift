import AVFoundation
import SwiftUI

struct TTSVoicesListView: View {
  @ObservedObject var settingsManager: SettingsManager
  @State private var voices: [Voice] = []
  @State private var sortedVoices: [Voice] = []
  private let previewSynthesizer = AVSpeechSynthesizer()

  var body: some View {
    Section("Tap a voice to preview and set it as default") {
      List {
        ForEach(sortedVoices, id: \.self.id) { voice in
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
  }

  private func updateSortedVoices() {
    sortedVoices = voices.sorted { v1, v2 in
      if v1.language != v2.language {
        return v1.language.localizedCaseInsensitiveCompare(v2.language) == .orderedAscending
      }
      return v1.name.localizedCaseInsensitiveCompare(v2.name) == .orderedAscending
    }
  }

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
    previewSynthesizer.speak(utterance)
  }
}
