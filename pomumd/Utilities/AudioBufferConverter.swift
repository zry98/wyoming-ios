/// Centralized audio buffer conversion utilities.
///
/// Consolidates conversion logic between AVAudioPCMBuffer and Data formats.

import AVFoundation
import Foundation

enum AudioBufferConverter {

  enum ConversionError: Error, LocalizedError {
    case invalidFormat
    case unsupportedBitDepth(UInt32)
    case bufferCreationFailed
    case noChannelData
    case emptyBuffer
    case conversionFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidFormat:
        return "Invalid audio format"
      case .unsupportedBitDepth(let depth):
        return "Unsupported bit depth: \(depth)"
      case .bufferCreationFailed:
        return "Failed to create audio buffer"
      case .noChannelData:
        return "Buffer has no valid channel data"
      case .emptyBuffer:
        return "Buffer is empty"
      case .conversionFailed(let reason):
        return "Conversion failed: \(reason)"
      }
    }
  }

  // MARK: - Buffer to Data

  /// Converts AVAudioPCMBuffer to Data.
  ///
  /// Supports Int16, Int32, and Float32 formats. Float32 samples are converted to Int16.
  static func convertToData(_ buffer: AVAudioPCMBuffer) throws -> Data {
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)

    guard frames > 0 else {
      throw ConversionError.emptyBuffer
    }

    var output = Data()
    output.reserveCapacity(frames * channels * 2)

    if let channelData = buffer.int16ChannelData {
      for frame in 0..<frames {
        for channel in 0..<channels {
          var value = channelData[channel][frame].littleEndian
          output.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
      }
      return output
    }

    if let channelData = buffer.int32ChannelData {
      output.reserveCapacity(frames * channels * 4)
      for frame in 0..<frames {
        for channel in 0..<channels {
          var value = channelData[channel][frame].littleEndian
          output.append(Data(bytes: &value, count: MemoryLayout<Int32>.size))
        }
      }
      return output
    }

    if let channelData = buffer.floatChannelData {
      for frame in 0..<frames {
        for channel in 0..<channels {
          let sample = channelData[channel][frame]
          let clampedSample = max(-1.0, min(1.0, sample))
          let int16Sample = Int16(clampedSample * Float(Int16.max))
          var value = int16Sample.littleEndian
          output.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
      }
      return output
    }

    throw ConversionError.noChannelData
  }

  // MARK: - Data to Buffer

  /// Converts Data to AVAudioPCMBuffer.
  ///
  /// Assumes Int16 PCM format (2 bytes per sample).
  static func convertToBuffer(from data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard data.count > 0 else {
      throw ConversionError.emptyBuffer
    }

    let frameCount = data.count / 2

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else {
      throw ConversionError.bufferCreationFailed
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)

    guard let channelData = buffer.int16ChannelData else {
      throw ConversionError.noChannelData
    }

    data.withUnsafeBytes { rawBufferPointer in
      guard let baseAddress = rawBufferPointer.baseAddress else { return }
      let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
      channelData[0].update(from: int16Pointer, count: frameCount)
    }

    return buffer
  }

  // MARK: - Format Detection

  static func detectFormat(from buffer: AVAudioPCMBuffer) -> AudioFormat {
    let format = buffer.format
    let rate = UInt32(format.sampleRate)
    let channels = UInt32(format.channelCount)

    let width: UInt32
    if format.commonFormat == .pcmFormatFloat32 {
      width = 2  // Float32 converted to Int16
    } else {
      width = format.streamDescription.pointee.mBytesPerFrame / channels
    }

    return AudioFormat(rate: rate, width: width, channels: channels)
  }

  // MARK: - Resampling

  static func resample(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
    guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
      throw ConversionError.conversionFailed("Failed to create audio converter")
    }

    let inputFrameCount = buffer.frameLength
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio)

    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputFrameCapacity
      )
    else {
      throw ConversionError.bufferCreationFailed
    }

    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
    if status == .error {
      throw ConversionError.conversionFailed(error?.localizedDescription ?? "unknown error")
    }

    return outputBuffer
  }
}
