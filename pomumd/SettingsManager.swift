import AVFoundation
import Combine
import Foundation

@MainActor
class SettingsManager: ObservableObject {
  static let userDefaultsKeyDefaultTTSVoice = "defaultTTSVoice"
  static let userDefaultsKeyDefaultSTTLanguage = "defaultSTTLanguage"
  static let userDefaultsKeyDefaultTTSRate = "defaultTTSRate"
  static let userDefaultsKeyDefaultTTSPitch = "defaultTTSPitch"
  static let userDefaultsKeyDefaultTTSPause = "defaultTTSPause"
  static let userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings =
    "defaultTTSPrefersAssistiveTechnologySettings"

  @Published var defaultTTSVoice: String {
    didSet {
      UserDefaults.standard.set(defaultTTSVoice, forKey: Self.userDefaultsKeyDefaultTTSVoice)
    }
  }

  @Published var defaultSTTLanguage: String {
    didSet {
      UserDefaults.standard.set(defaultSTTLanguage, forKey: Self.userDefaultsKeyDefaultSTTLanguage)
    }
  }

  @Published var defaultTTSRate: Double {
    didSet {
      UserDefaults.standard.set(defaultTTSRate, forKey: Self.userDefaultsKeyDefaultTTSRate)
    }
  }

  @Published var defaultTTSPitch: Double {
    didSet {
      UserDefaults.standard.set(defaultTTSPitch, forKey: Self.userDefaultsKeyDefaultTTSPitch)
    }
  }

  @Published var defaultTTSPause: Double {
    didSet {
      UserDefaults.standard.set(defaultTTSPause, forKey: Self.userDefaultsKeyDefaultTTSPause)
    }
  }

  @Published var defaultTTSPrefersAssistiveTechnologySettings: Bool {
    didSet {
      UserDefaults.standard.set(
        defaultTTSPrefersAssistiveTechnologySettings,
        forKey: Self.userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings)
    }
  }

  init() {
    let rate = UserDefaults.standard.double(forKey: Self.userDefaultsKeyDefaultTTSRate)
    let pitch = UserDefaults.standard.double(forKey: Self.userDefaultsKeyDefaultTTSPitch)
    let pause = UserDefaults.standard.double(forKey: Self.userDefaultsKeyDefaultTTSPause)

    self.defaultTTSVoice = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultTTSVoice) ?? ""
    self.defaultSTTLanguage = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultSTTLanguage) ?? ""
    self.defaultTTSRate = rate == 0.0 ? Double(AVSpeechUtteranceDefaultSpeechRate) : rate
    self.defaultTTSPitch = pitch == 0.0 ? 1.0 : pitch
    self.defaultTTSPause = pause == 0.0 ? 0.3 : pause
    self.defaultTTSPrefersAssistiveTechnologySettings = UserDefaults.standard.bool(
      forKey: Self.userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings)
  }

  func resetTTSSettings() {
    self.defaultTTSRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    self.defaultTTSPitch = 1.0
    self.defaultTTSPause = 0.3
    self.defaultTTSPrefersAssistiveTechnologySettings = false
  }

  func validateTTSVoice(_ voiceID: String) throws {
    guard !voiceID.isEmpty else {
      // empty will fallback to system default
      return
    }

    let availableVoices = TTSService.getAvailableVoices()

    guard availableVoices.contains(where: { $0.id == voiceID }) else {
      throw SettingsError.invalidVoice("Voice '\(voiceID)' not found")
    }
  }

  func validateSTTLanguage(_ langID: String) throws {
    guard !langID.isEmpty else {
      // empty will fallback to system default
      return
    }

    let availableLanguages = STTService.getLanguages()

    guard availableLanguages.contains(langID) else {
      throw SettingsError.invalidLanguage("Language '\(langID)' not found")
    }
  }

  struct Settings: Codable {
    let defaultTTSVoice: String
    let defaultSTTLanguage: String
    let defaultTTSRate: Double
    let defaultTTSPitch: Double
    let defaultTTSPause: Double
    let defaultTTSPrefersAssistiveTechnologySettings: Bool
  }

  func toSettings() -> Settings {
    return Settings(
      defaultTTSVoice: defaultTTSVoice,
      defaultSTTLanguage: defaultSTTLanguage,
      defaultTTSRate: defaultTTSRate,
      defaultTTSPitch: defaultTTSPitch,
      defaultTTSPause: defaultTTSPause,
      defaultTTSPrefersAssistiveTechnologySettings: defaultTTSPrefersAssistiveTechnologySettings
    )
  }

  func updateFromSettings(_ settings: Settings) throws {
    try validateTTSVoice(settings.defaultTTSVoice)
    try validateSTTLanguage(settings.defaultSTTLanguage)

    self.defaultTTSVoice = settings.defaultTTSVoice
    self.defaultSTTLanguage = settings.defaultSTTLanguage
    self.defaultTTSRate = settings.defaultTTSRate
    self.defaultTTSPitch = settings.defaultTTSPitch
    self.defaultTTSPause = settings.defaultTTSPause
    self.defaultTTSPrefersAssistiveTechnologySettings = settings.defaultTTSPrefersAssistiveTechnologySettings
  }

  func updatePartial(
    defaultTTSVoice: String? = nil,
    defaultSTTLanguage: String? = nil,
    defaultTTSRate: Double? = nil,
    defaultTTSPitch: Double? = nil,
    defaultTTSPause: Double? = nil,
    defaultTTSPrefersAssistiveTechnologySettings: Bool? = nil
  ) throws {
    let newTTSVoice = defaultTTSVoice ?? self.defaultTTSVoice
    let newSTTLang = defaultSTTLanguage ?? self.defaultSTTLanguage

    try validateTTSVoice(newTTSVoice)
    try validateSTTLanguage(newSTTLang)

    if let voice = defaultTTSVoice { self.defaultTTSVoice = voice }
    if let lang = defaultSTTLanguage { self.defaultSTTLanguage = lang }
    if let rate = defaultTTSRate { self.defaultTTSRate = rate }
    if let pitch = defaultTTSPitch { self.defaultTTSPitch = pitch }
    if let pause = defaultTTSPause { self.defaultTTSPause = pause }
    if let prefersAssistive = defaultTTSPrefersAssistiveTechnologySettings {
      self.defaultTTSPrefersAssistiveTechnologySettings = prefersAssistive
    }
  }
}

enum SettingsError: Error, LocalizedError {
  case invalidVoice(String)
  case invalidLanguage(String)

  var errorDescription: String? {
    switch self {
    case .invalidVoice(let msg),
      .invalidLanguage(let msg):
      return msg
    }
  }
}
