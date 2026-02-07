import AVFoundation
import Foundation

/// Audio format specification for Wyoming protocol.
struct AudioFormat: Codable, Equatable {
  let rate: UInt32  // Sample rate in Hz (e.g., 16000, 22050, 44100)
  let width: UInt32  // Bytes per sample (2 for Int16, 4 for Int32/Float32)
  let channels: UInt32  // Number of audio channels (1=mono, 2=stereo)

  /// Common format used by Wyoming protocol clients (16kHz mono Int16).
  static let commonFormat = AudioFormat(rate: 16000, width: 2, channels: 1)

  /// Converts to AVAudioFormat with PCM Int16 interleaved format.
  func toAVAudioFormat() -> AVAudioFormat? {
    return AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(rate),
      channels: AVAudioChannelCount(channels),
      interleaved: true
    )
  }

  var isValid: Bool {
    return rate > 0 && channels > 0 && (width == 2 || width == 4)
  }

  var description: String {
    return "\(rate) Hz, \(width) bytes/sample, \(channels) channel(s)"
  }
}
