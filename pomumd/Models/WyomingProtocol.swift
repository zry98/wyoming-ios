import Foundation

let version = "1.7.2"

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

enum WyomingProtocol {
  static func parseMessage(from data: Data) -> WyomingMessage? {
    guard let newlineIdx = data.firstIndex(of: 0x0A) else {
      return nil
    }

    let headerData = Data(data.prefix(newlineIdx))
    if let headerString = String(data: headerData, encoding: .utf8) {
      wyomingServerLogger.debug("Header: \(headerString)")
    }

    let header: WyomingHeader
    do {
      header = try jsonDecoder.decode(WyomingHeader.self, from: headerData)
    } catch {
      wyomingServerLogger.error("Failed to decode header: \(error)")
      if let bufferPreview = String(data: data.prefix(min(200, data.count)), encoding: .utf8) {
        wyomingServerLogger.debug("Buffer preview: \(bufferPreview)")
      }
      return nil
    }

    let dataLen = header.dataLength ?? 0
    let payloadLen = header.payloadLength ?? 0
    let headerSize = newlineIdx + 1  // +1 for newline after header
    let expectedSize = headerSize + dataLen + payloadLen

    wyomingServerLogger.debug(
      "Message type=\(header.type), newlineIdx=\(newlineIdx), headerSize=\(headerSize), dataLen=\(dataLen), payloadLen=\(payloadLen), expectedSize=\(expectedSize), bufferSize=\(data.count)"
    )

    if data.count < expectedSize {
      wyomingServerLogger.debug("Incomplete message: have \(data.count) bytes, need \(expectedSize) bytes")
      return nil
    }

    var dataBytes: Data?
    var payload: Data?

    // parse data if present
    if dataLen > 0 {
      let dataStart = headerSize
      let dataEnd = dataStart + dataLen

      guard dataEnd <= data.count else {
        wyomingServerLogger.error("Invalid data range: \(dataStart)..<\(dataEnd), data.count: \(data.count)")
        return nil
      }

      dataBytes = data.subdata(in: dataStart..<dataEnd)
    }

    // extract payload if present (comes immediately after data)
    if payloadLen > 0 {
      let payloadStart = headerSize + dataLen
      let payloadEnd = payloadStart + payloadLen

      guard payloadEnd <= data.count else {
        wyomingServerLogger.error("Invalid payload range: \(payloadStart)..<\(payloadEnd), data.count: \(data.count)")
        return nil
      }

      payload = data.subdata(in: payloadStart..<payloadEnd)
    }

    return WyomingMessage(type: header.type, dataBytes: dataBytes, payload: payload, messageSize: expectedSize)
  }

  static func serializeMessage(_ message: WyomingMessage) -> Data {
    var result = Data()

    let header = WyomingHeader(
      type: message.type,
      version: version,
      dataLength: (message.dataBytes?.count ?? 0) > 0 ? message.dataBytes?.count : nil,
      payloadLength: (message.payload?.count ?? 0) > 0 ? message.payload?.count : nil
    )

    if let headerData = try? jsonEncoder.encode(header) {
      result.append(headerData)
      result.append(0x0A)  // newline
    }

    if let dataBytes = message.dataBytes {
      result.append(dataBytes)
    }

    if let payload = message.payload {
      result.append(payload)
    }

    return result
  }
}

struct WyomingHeader: Codable {
  let type: EventType
  let version: String?
  let dataLength: Int?
  let payloadLength: Int?

  enum CodingKeys: String, CodingKey {
    case type
    case version
    case dataLength = "data_length"
    case payloadLength = "payload_length"
  }

  init(type: EventType, version: String? = "1.0.0", dataLength: Int? = nil, payloadLength: Int? = nil) {
    self.type = type
    self.version = version
    self.dataLength = dataLength
    self.payloadLength = payloadLength
  }
}

struct WyomingMessage {
  let type: EventType
  let dataBytes: Data?
  let payload: Data?
  let messageSize: Int

  init(type: EventType, dataBytes: Data? = nil, payload: Data? = nil, messageSize: Int = 0) {
    self.type = type
    self.dataBytes = dataBytes
    self.payload = payload
    self.messageSize = messageSize
  }
}

enum EventType: String, Codable {
  case describe = "describe"
  case info = "info"
  case synthesize = "synthesize"
  case transcribe = "transcribe"
  case audioStart = "audio-start"
  case audioChunk = "audio-chunk"
  case audioStop = "audio-stop"
  case transcript = "transcript"
  case transcriptStart = "transcript-start"
  case transcriptChunk = "transcript-chunk"
  case transcriptStop = "transcript-stop"
  case synthesizeStart = "synthesize-start"
  case synthesizeChunk = "synthesize-chunk"
  case synthesizeStop = "synthesize-stop"
  case synthesizeStopped = "synthesize-stopped"
}

protocol WyomingEvent {
  static var eventType: EventType { get }

  func toMessage() -> WyomingMessage
  static func fromMessage(_ message: WyomingMessage) throws -> Self
}

enum WyomingEventError: Error {
  case invalidEventType(expected: EventType, got: EventType)
  case missingRequiredField(String)
}

extension WyomingEvent where Self: Codable {
  func toMessage() -> WyomingMessage {
    do {
      let dataBytes = try jsonEncoder.encode(self)
      return WyomingMessage(type: Self.eventType, dataBytes: dataBytes)
    } catch {
      wyomingServerLogger.error("Failed to encode \(Self.self): \(error)")
      return WyomingMessage(type: Self.eventType, dataBytes: nil)
    }
  }

  static func fromMessage(_ message: WyomingMessage) throws -> Self {
    guard message.type == eventType else {
      throw WyomingEventError.invalidEventType(expected: eventType, got: message.type)
    }
    let dataBytes = message.dataBytes ?? Data("{}".utf8)
    return try jsonDecoder.decode(Self.self, from: dataBytes)
  }
}

struct AudioData: Codable {
  let rate: UInt32
  let width: UInt32
  let channels: UInt32
  let timestamp: Int?

  init(format: AudioFormat, timestamp: Int?) {
    self.rate = format.rate
    self.width = format.width
    self.channels = format.channels
    self.timestamp = timestamp
  }

  func toAudioFormat() -> AudioFormat {
    return AudioFormat(rate: rate, width: width, channels: channels)
  }
}

struct AudioChunkEvent: WyomingEvent {
  static let eventType = EventType.audioChunk
  let format: AudioFormat
  let audio: Data
  let timestamp: Int?

  func toMessage() -> WyomingMessage {
    do {
      let audioData = AudioData(format: format, timestamp: timestamp)
      let dataBytes = try jsonEncoder.encode(audioData)
      return WyomingMessage(type: Self.eventType, dataBytes: dataBytes, payload: audio)
    } catch {
      wyomingServerLogger.error("Failed to encode AudioChunkEvent: \(error)")
      return WyomingMessage(type: Self.eventType, dataBytes: nil, payload: audio)
    }
  }

  static func fromMessage(_ message: WyomingMessage) throws -> AudioChunkEvent {
    guard message.type == eventType else {
      throw WyomingEventError.invalidEventType(expected: eventType, got: message.type)
    }
    guard let dataBytes = message.dataBytes else {
      throw WyomingEventError.missingRequiredField("dataBytes")
    }

    let audioData = try jsonDecoder.decode(AudioData.self, from: dataBytes)
    let format = audioData.toAudioFormat()
    let audio = message.payload ?? Data()

    return AudioChunkEvent(format: format, audio: audio, timestamp: audioData.timestamp)
  }
}

struct AudioStartEvent: WyomingEvent {
  static let eventType = EventType.audioStart
  let format: AudioFormat
  let timestamp: Int?

  func toMessage() -> WyomingMessage {
    do {
      let audioData = AudioData(format: format, timestamp: timestamp)
      let dataBytes = try jsonEncoder.encode(audioData)
      return WyomingMessage(type: Self.eventType, dataBytes: dataBytes)
    } catch {
      wyomingServerLogger.error("Failed to encode AudioStartEvent: \(error)")
      return WyomingMessage(type: Self.eventType, dataBytes: nil)
    }
  }

  static func fromMessage(_ message: WyomingMessage) throws -> AudioStartEvent {
    guard message.type == eventType else {
      throw WyomingEventError.invalidEventType(expected: eventType, got: message.type)
    }
    guard let dataBytes = message.dataBytes else {
      throw WyomingEventError.missingRequiredField("dataBytes")
    }

    let audioData = try jsonDecoder.decode(AudioData.self, from: dataBytes)
    let format = audioData.toAudioFormat()

    return AudioStartEvent(format: format, timestamp: audioData.timestamp)
  }
}

struct AudioStopEvent: WyomingEvent, Codable {
  static let eventType = EventType.audioStop
  let timestamp: Int?
}

struct TranscribeEvent: WyomingEvent, Codable {
  static let eventType = EventType.transcribe
  let name: String?
  let language: String?
}

struct TranscriptEvent: WyomingEvent, Codable {
  static let eventType = EventType.transcript
  let text: String
  let language: String?
}

struct TranscriptStartEvent: WyomingEvent, Codable {
  static let eventType = EventType.transcriptStart
  let language: String?
}

struct TranscriptChunkEvent: WyomingEvent, Codable {
  static let eventType = EventType.transcriptChunk
  let text: String
  let language: String?
}

struct TranscriptStopEvent: WyomingEvent, Codable {
  static let eventType = EventType.transcriptStop
}

struct SynthesizeVoice: Codable {
  let name: String?
  let language: String?
  let speaker: String?
}

struct SynthesizeEvent: WyomingEvent, Codable {
  static let eventType = EventType.synthesize
  let text: String
  let voice: SynthesizeVoice?
}

struct SynthesizeStartEvent: WyomingEvent, Codable {
  static let eventType = EventType.synthesizeStart
  let voice: SynthesizeVoice?
}

struct SynthesizeChunkEvent: WyomingEvent, Codable {
  static let eventType = EventType.synthesizeChunk
  let text: String
}

struct SynthesizeStopEvent: WyomingEvent, Codable {
  static let eventType = EventType.synthesizeStop
}

struct SynthesizeStoppedEvent: WyomingEvent, Codable {
  static let eventType = EventType.synthesizeStopped
}

struct DescribeEvent: WyomingEvent, Codable {
  static let eventType = EventType.describe
}

struct Attribution: Codable {
  let name: String
  let url: String

  static let apple = Attribution(name: "Apple", url: "https://www.apple.com")
  static let pomumd = Attribution(name: "PomumD", url: "https://github.com/zry98/pomumd")
}

struct ASRModel: Codable {
  let name: String
  let attribution: Attribution
  let installed: Bool
  let description: String?
  let version: String?
  let languages: [String]
}

struct ASRProgram: Codable {
  let name: String
  let attribution: Attribution
  let installed: Bool
  let description: String?
  let version: String?
  let models: [ASRModel]
  let supportsTranscriptStreaming: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case attribution
    case installed
    case description
    case version
    case models
    case supportsTranscriptStreaming = "supports_transcript_streaming"
  }
}

struct TTSVoiceSpeaker: Codable {
  let name: String
}

struct TTSVoice: Codable {
  let name: String
  let attribution: Attribution
  let installed: Bool
  let description: String?
  let version: String?
  let languages: [String]
  let speakers: [TTSVoiceSpeaker]?  // not supported yet
}

struct TTSProgram: Codable {
  let name: String
  let attribution: Attribution
  let installed: Bool
  let description: String?
  let version: String?
  let voices: [TTSVoice]
  let supportsSynthesizeStreaming: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case attribution
    case installed
    case description
    case version
    case voices
    case supportsSynthesizeStreaming = "supports_synthesize_streaming"
  }
}

struct InfoEvent: WyomingEvent, Codable {
  static let eventType = EventType.info
  let asr: [ASRProgram]
  let tts: [TTSProgram]
}
