import AVFoundation
import Foundation

struct AudioFormat: Codable, Equatable {
  let rate: UInt32
  let width: UInt32
  let channels: UInt32

  /// Common audio format used by Wyoming protocol clients
  static let commonFormat = AudioFormat(rate: 16000, width: 2, channels: 1)

  /// Creates an AVAudioFormat for PCM Int16 audio
  func toAVAudioFormat() -> AVAudioFormat? {
    return AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(rate),
      channels: AVAudioChannelCount(channels),
      interleaved: true
    )
  }
}
