import AVFoundation
import Combine
import Foundation

/// Default settings values
let defaultPitch: Float = 1.0  // Normal pitch multiplier
let defaultPause: Float = 0.3  // Pause between sentences in seconds
let defaultSynthesisTimeout: Int = 5  // Base timeout for synthesis in seconds

/// Manages persistent settings with UserDefaults.
@MainActor
class SettingsManager: ObservableObject {
  // UserDefaults keys for persistent storage
  static let userDefaultsKeyDefaultTTSSynthesisTimeout = "defaultTTSSynthesisTimeout"
  static let userDefaultsKeyDefaultTTSVoice = "defaultTTSVoice"
  static let userDefaultsKeyDefaultSTTLanguage = "defaultSTTLanguage"
  static let userDefaultsKeyDefaultTTSRate = "defaultTTSRate"
  static let userDefaultsKeyDefaultTTSPitch = "defaultTTSPitch"
  static let userDefaultsKeyDefaultTTSPause = "defaultTTSPause"
  static let userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings =
    "defaultTTSPrefersAssistiveTechnologySettings"

  // MARK: - Published Properties

  @Published var defaultTTSSynthesisTimeout: Int {
    didSet {
      UserDefaults.standard.set(defaultTTSSynthesisTimeout, forKey: Self.userDefaultsKeyDefaultTTSSynthesisTimeout)
    }
  }

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

  @Published var defaultTTSRate: Float {
    didSet {
      UserDefaults.standard.set(defaultTTSRate, forKey: Self.userDefaultsKeyDefaultTTSRate)
    }
  }

  @Published var defaultTTSPitch: Float {
    didSet {
      UserDefaults.standard.set(defaultTTSPitch, forKey: Self.userDefaultsKeyDefaultTTSPitch)
    }
  }

  @Published var defaultTTSPause: Float {
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
    let ttsTimeout = UserDefaults.standard.integer(forKey: Self.userDefaultsKeyDefaultTTSSynthesisTimeout)
    let ttsRate = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSRate)
    let ttsPitch = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSPitch)
    let ttsPause = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSPause)

    self.defaultTTSSynthesisTimeout = ttsTimeout == 0 ? defaultSynthesisTimeout : ttsTimeout
    self.defaultTTSVoice = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultTTSVoice) ?? ""
    self.defaultSTTLanguage = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultSTTLanguage) ?? ""
    self.defaultTTSRate = ttsRate == 0.0 ? AVSpeechUtteranceDefaultSpeechRate : ttsRate
    self.defaultTTSPitch = ttsPitch == 0.0 ? defaultPitch : ttsPitch
    self.defaultTTSPause = ttsPause == 0.0 ? defaultPause : ttsPause
    self.defaultTTSPrefersAssistiveTechnologySettings = UserDefaults.standard.bool(
      forKey: Self.userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings)
  }

  // MARK: - Settings Management

  /// Resets all TTS voice parameters to system defaults
  func resetTTSVoiceSettings() {
    self.defaultTTSRate = AVSpeechUtteranceDefaultSpeechRate
    self.defaultTTSPitch = defaultPitch
    self.defaultTTSPause = defaultPause
    self.defaultTTSPrefersAssistiveTechnologySettings = false
  }

  /// Validates that a voice ID exists in available system voices.
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

  /// Validates that a language ID is supported by the STT service.
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

  // MARK: - Serialization

  /// Serializable settings structure for HTTP API requests.
  struct Settings: Codable {
    let defaultTTSSynthesisTimeout: Int?
    let defaultTTSVoice: String?
    let defaultSTTLanguage: String?
    let defaultTTSRate: Float?
    let defaultTTSPitch: Float?
    let defaultTTSPause: Float?
    let defaultTTSPrefersAssistiveTechnologySettings: Bool?
  }

  func toSettings() -> Settings {
    return Settings(
      defaultTTSSynthesisTimeout: defaultTTSSynthesisTimeout,
      defaultTTSVoice: defaultTTSVoice,
      defaultSTTLanguage: defaultSTTLanguage,
      defaultTTSRate: defaultTTSRate,
      defaultTTSPitch: defaultTTSPitch,
      defaultTTSPause: defaultTTSPause,
      defaultTTSPrefersAssistiveTechnologySettings: defaultTTSPrefersAssistiveTechnologySettings,
    )
  }

  /// Updates settings from HTTP API request.
  func updateFromSettings(_ settings: Settings) throws {
    let newTTSVoice = settings.defaultTTSVoice ?? self.defaultTTSVoice
    let newSTTLang = settings.defaultSTTLanguage ?? self.defaultSTTLanguage

    try validateTTSVoice(newTTSVoice)
    try validateSTTLanguage(newSTTLang)

    if let timeout = settings.defaultTTSSynthesisTimeout { self.defaultTTSSynthesisTimeout = timeout }
    if let voice = settings.defaultTTSVoice { self.defaultTTSVoice = voice }
    if let lang = settings.defaultSTTLanguage { self.defaultSTTLanguage = lang }
    if let rate = settings.defaultTTSRate { self.defaultTTSRate = rate }
    if let pitch = settings.defaultTTSPitch { self.defaultTTSPitch = pitch }
    if let pause = settings.defaultTTSPause { self.defaultTTSPause = pause }
    if let prefersAssistive = settings.defaultTTSPrefersAssistiveTechnologySettings {
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
