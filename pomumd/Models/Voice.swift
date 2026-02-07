import AVFoundation
import Foundation

/// Model representing a TTS voice with quality information.
///
/// Wraps AVSpeechSynthesisVoice for Wyoming protocol serialization.
struct Voice: Identifiable, Codable, Equatable {
  let id: String  // AVSpeechSynthesisVoice identifier (e.g., "com.apple.voice.compact.en-US.Samantha")
  let name: String  // AVSpeechSynthesisVoice name (e.g., "Samantha")
  let language: String  // BCP 47 language code (e.g., "en-US")
  let quality: String  // Human-readable quality level (e.g., "Enhanced")

  init(id: String, name: String, language: String, quality: String = "default") {
    self.id = id
    self.name = name
    self.language = language
    self.quality = quality
  }

  /// Creates a Voice from an AVSpeechSynthesisVoice.
  init(from avVoice: AVSpeechSynthesisVoice) {
    self.id = avVoice.identifier
    self.name = avVoice.name
    self.language = avVoice.language

    switch avVoice.quality {
    case .default:
      self.quality = "Compact"
    case .enhanced:
      self.quality = "Enhanced"
    case .premium:
      self.quality = "Premium"
    @unknown default:
      self.quality = "Unknown"
    }
  }
}
