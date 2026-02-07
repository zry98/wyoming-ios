import SwiftUI

/// STT language selection view.
struct STTLanguagesListView: View {
  @ObservedObject var settingsManager: SettingsManager
  @State private var languages: [String] = []
  @State private var sortedLanguages: [String] = []

  var body: some View {
    List {
      Section("Tap a language to set it as default") {
        ForEach(sortedLanguages, id: \.self) { language in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(Locale.current.localizedString(forIdentifier: language) ?? language)
              Text(language)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if settingsManager.defaultSTTLanguage == language {
              Image(systemName: "checkmark")
                .foregroundColor(.blue)
            }
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .onTapGesture {
            if settingsManager.defaultSTTLanguage == language {
              settingsManager.defaultSTTLanguage = ""
            } else {
              settingsManager.defaultSTTLanguage = language
            }
          }
        }
      }
    }
    .navigationTitle("STT Languages")
    .inlineNavigationBarTitle()
    .onAppear {
      languages = STTService.getLanguages()
      updateSortedLanguages()
    }
    .onChange(of: languages) { _ in
      updateSortedLanguages()
    }
  }

  private func updateSortedLanguages() {
    sortedLanguages = languages.sorted { l1, l2 in
      return l1.localizedCaseInsensitiveCompare(l2) == .orderedAscending
    }
  }
}
