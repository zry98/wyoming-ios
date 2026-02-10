import AVFoundation
import Combine
import Foundation

/// Default settings values
let defaultPitch: Float = 1.0  // Normal pitch multiplier
let defaultPause: Float = 0.3  // Pause between sentences in seconds
let defaultSynthesisTimeout: Int = 5  // Base timeout for TTS synthesis in seconds

/// Manages persistent settings with UserDefaults.
@MainActor
class SettingsManager: ObservableObject {
  // UserDefaults keys for persistent storage
  static let userDefaultsKeyDefaultTTSSynthesisTimeout = "defaultTTSSynthesisTimeout"
  static let userDefaultsKeyDefaultTTSVoice = "defaultTTSVoice"
  static let userDefaultsKeyDefaultTTSRate = "defaultTTSRate"
  static let userDefaultsKeyDefaultTTSPitch = "defaultTTSPitch"
  static let userDefaultsKeyDefaultTTSPause = "defaultTTSPause"
  static let userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings =
    "defaultTTSPrefersAssistiveTechnologySettings"
  static let userDefaultsKeyDefaultSTTLanguage = "defaultSTTLanguage"
  static let userDefaultsKeyDefaultLLMModel = "defaultLLMModel"
  static let userDefaultsKeyDefaultLLMTemperature = "defaultLLMTemperature"
  static let userDefaultsKeyDefaultLLMMaxTokens = "defaultLLMMaxTokens"
  static let userDefaultsKeyDefaultLLMTopP = "defaultLLMTopP"
  static let userDefaultsKeyDefaultLLMAdditionalContext = "defaultLLMAdditionalContext"

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

  @Published var defaultSTTLanguage: String {
    didSet {
      UserDefaults.standard.set(defaultSTTLanguage, forKey: Self.userDefaultsKeyDefaultSTTLanguage)
    }
  }

  @Published var defaultLLMModel: String {
    didSet {
      UserDefaults.standard.set(defaultLLMModel, forKey: Self.userDefaultsKeyDefaultLLMModel)
    }
  }

  @Published var defaultLLMTemperature: Float {
    didSet {
      UserDefaults.standard.set(defaultLLMTemperature, forKey: Self.userDefaultsKeyDefaultLLMTemperature)
    }
  }

  @Published var defaultLLMMaxTokens: Int {
    didSet {
      UserDefaults.standard.set(defaultLLMMaxTokens, forKey: Self.userDefaultsKeyDefaultLLMMaxTokens)
    }
  }

  @Published var defaultLLMTopP: Float {
    didSet {
      UserDefaults.standard.set(defaultLLMTopP, forKey: Self.userDefaultsKeyDefaultLLMTopP)
    }
  }

  @Published var defaultLLMAdditionalContext: [LLMAdditionalContextItem] {
    didSet {
      if let encoded = try? JSONEncoder().encode(defaultLLMAdditionalContext) {
        UserDefaults.standard.set(encoded, forKey: Self.userDefaultsKeyDefaultLLMAdditionalContext)
      }
    }
  }

  init() {
    // TTS settings
    let ttsTimeout = UserDefaults.standard.integer(forKey: Self.userDefaultsKeyDefaultTTSSynthesisTimeout)
    let ttsRate = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSRate)
    let ttsPitch = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSPitch)
    let ttsPause = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultTTSPause)
    self.defaultTTSSynthesisTimeout = ttsTimeout == 0 ? defaultSynthesisTimeout : ttsTimeout
    self.defaultTTSVoice = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultTTSVoice) ?? ""
    self.defaultTTSRate = ttsRate == 0.0 ? AVSpeechUtteranceDefaultSpeechRate : ttsRate
    self.defaultTTSPitch = ttsPitch == 0.0 ? defaultPitch : ttsPitch
    self.defaultTTSPause = ttsPause == 0.0 ? defaultPause : ttsPause
    self.defaultTTSPrefersAssistiveTechnologySettings = UserDefaults.standard.bool(
      forKey: Self.userDefaultsKeyDefaultTTSPrefersAssistiveTechnologySettings)
    // STT settings
    self.defaultSTTLanguage = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultSTTLanguage) ?? ""

    // LLM settings
    let llmTemperature = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultLLMTemperature)
    let llmMaxTokens = UserDefaults.standard.integer(forKey: Self.userDefaultsKeyDefaultLLMMaxTokens)
    let llmTopP = UserDefaults.standard.float(forKey: Self.userDefaultsKeyDefaultLLMTopP)
    self.defaultLLMModel = UserDefaults.standard.string(forKey: Self.userDefaultsKeyDefaultLLMModel) ?? "qwen3-4b"
    self.defaultLLMTemperature = llmTemperature == 0.0 ? 0.7 : llmTemperature
    self.defaultLLMMaxTokens = llmMaxTokens == 0 ? 512 : llmMaxTokens
    self.defaultLLMTopP = llmTopP == 0.0 ? 1.0 : llmTopP
    if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKeyDefaultLLMAdditionalContext),
      let decoded = try? JSONDecoder().decode([LLMAdditionalContextItem].self, from: data)
    {
      self.defaultLLMAdditionalContext = decoded
    } else {
      self.defaultLLMAdditionalContext = []
    }
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

  /// Validates that an LLM model exists in the available models list.
  func validateLLMModel(_ modelID: String, availableModels: [String]) throws {
    guard !modelID.isEmpty else {
      throw SettingsError.invalidModel("Model ID cannot be empty")
    }

    guard availableModels.contains(modelID) else {
      throw SettingsError.invalidModel("Model '\(modelID)' not found")
    }
  }

  // MARK: - Serialization

  /// Serializable settings structure for HTTP API requests.
  struct Settings: Codable {
    let defaultTTSSynthesisTimeout: Int?
    let defaultTTSVoice: String?
    let defaultTTSRate: Float?
    let defaultTTSPitch: Float?
    let defaultTTSPause: Float?
    let defaultTTSPrefersAssistiveTechnologySettings: Bool?
    let defaultSTTLanguage: String?
    let defaultLLMModel: String?
    let defaultLLMTemperature: Float?
    let defaultLLMMaxTokens: Int?
    let defaultLLMTopP: Float?
  }

  func toSettings() -> Settings {
    return Settings(
      defaultTTSSynthesisTimeout: defaultTTSSynthesisTimeout,
      defaultTTSVoice: defaultTTSVoice,
      defaultTTSRate: defaultTTSRate,
      defaultTTSPitch: defaultTTSPitch,
      defaultTTSPause: defaultTTSPause,
      defaultTTSPrefersAssistiveTechnologySettings: defaultTTSPrefersAssistiveTechnologySettings,
      defaultSTTLanguage: defaultSTTLanguage,
      defaultLLMModel: defaultLLMModel,
      defaultLLMTemperature: defaultLLMTemperature,
      defaultLLMMaxTokens: defaultLLMMaxTokens,
      defaultLLMTopP: defaultLLMTopP
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
    if let rate = settings.defaultTTSRate { self.defaultTTSRate = rate }
    if let pitch = settings.defaultTTSPitch { self.defaultTTSPitch = pitch }
    if let pause = settings.defaultTTSPause { self.defaultTTSPause = pause }
    if let prefersAssistive = settings.defaultTTSPrefersAssistiveTechnologySettings {
      self.defaultTTSPrefersAssistiveTechnologySettings = prefersAssistive
    }

    if let lang = settings.defaultSTTLanguage { self.defaultSTTLanguage = lang }

    if let model = settings.defaultLLMModel { self.defaultLLMModel = model }
    if let temperature = settings.defaultLLMTemperature { self.defaultLLMTemperature = temperature }
    if let maxTokens = settings.defaultLLMMaxTokens { self.defaultLLMMaxTokens = maxTokens }
    if let topP = settings.defaultLLMTopP { self.defaultLLMTopP = topP }
  }
}

enum SettingsError: Error, LocalizedError {
  case invalidVoice(String)
  case invalidLanguage(String)
  case invalidModel(String)

  var errorDescription: String? {
    switch self {
    case .invalidVoice(let msg),
      .invalidLanguage(let msg),
      .invalidModel(let msg):
      return msg
    }
  }
}
