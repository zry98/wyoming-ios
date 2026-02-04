import AVFoundation
import Foundation
import NaturalLanguage

class TTSService {
  private static let appleAttribution = Attribution(name: "Apple", url: "https://www.apple.com")
  private static let programName: String = {
    let appName =
      (Bundle.main.infoDictionary?["CFBundleName"] as? String
      ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
      ?? "pomumd")
      .replacingOccurrences(of: " ", with: "-")
      .lowercased()
    return "\(appName)-wyoming-tts"
  }()

  private let synthesizer: AVSpeechSynthesizer
  private let metricsCollector: MetricsCollector

  init(metricsCollector: MetricsCollector) {
    self.synthesizer = AVSpeechSynthesizer()
    self.metricsCollector = metricsCollector
  }

  deinit {
    synthesizer.stopSpeaking(at: .immediate)
  }

  static func getAvailableVoices() -> [Voice] {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    return voices.map { Voice(from: $0) }
  }

  func getServiceInfo() -> [TTSProgram] {
    let voices = Self.getAvailableVoices()

    guard !voices.isEmpty else {
      return []
    }

    let ttsVoices = voices.map { voice in
      TTSVoice(
        name: voice.id,
        languages: [voice.language],
        attribution: Self.appleAttribution,
        installed: true,
        description: voice.id,
        version: nil
      )
    }

    let ttsProgram = TTSProgram(
      name: Self.programName,
      description: "Wyoming Text-to-Speech using iOS AVSpeechSynthesizer",
      installed: true,
      attribution: Self.appleAttribution,
      voices: ttsVoices,
      supportsSynthesizeStreaming: true
    )

    return [ttsProgram]
  }

  func synthesize(text: String, voiceIdentifier: String?) async throws -> (data: Data, format: AudioFormat) {
    var accumulated = Data()
    var capturedFormat: AudioFormat?

    try await synthesizeInternal(text: text, voiceIdentifier: voiceIdentifier) { data, format in
      accumulated.append(data)
      capturedFormat = format
    }

    return (data: accumulated, format: capturedFormat ?? AudioFormat.commonFormat)
  }

  private func convertBufferToData(_ buf: AVAudioPCMBuffer) -> Data? {
    let channels = Int(buf.format.channelCount)
    let frames = Int(buf.frameLength)

    guard frames > 0 else {
      ttsLogger.debug("Buffer has no frames")
      return nil
    }

    var output = Data()

    if let d = buf.int16ChannelData {
      for f in 0..<frames {
        for c in 0..<channels {
          var v = d[c][f].littleEndian
          output.append(Data(bytes: &v, count: MemoryLayout<Int16>.size))
        }
      }
      return output
    } else if let d = buf.int32ChannelData {
      for f in 0..<frames {
        for c in 0..<channels {
          var v = d[c][f].littleEndian
          output.append(Data(bytes: &v, count: MemoryLayout<Int32>.size))
        }
      }
      return output
    } else if let d = buf.floatChannelData {
      for f in 0..<frames {
        for c in 0..<channels {
          let sample = d[c][f]
          let clampedSample = max(-1.0, min(1.0, sample))
          let int16Sample = Int16(clampedSample * Float(Int16.max))
          var v = int16Sample.littleEndian
          output.append(Data(bytes: &v, count: MemoryLayout<Int16>.size))
        }
      }
      return output
    } else {
      ttsLogger.debug("Buffer has no valid channel data")
      return nil
    }
  }

  private func isValidSSML(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    guard lowercased.hasPrefix("<?xml") || lowercased.hasPrefix("<speak") else {
      return false
    }
    guard let data = trimmed.data(using: .utf8) else {
      return false
    }

    let parser = XMLParser(data: data)
    let delegate = SSMLValidationDelegate()
    parser.delegate = delegate

    let isValid = parser.parse() && delegate.hasValidStructure
    return isValid
  }

  private func escapeXMLCharacters(_ text: String) -> String {
    var res = text
    res = res.replacingOccurrences(of: "&", with: "&amp;")
    res = res.replacingOccurrences(of: "<", with: "&lt;")
    res = res.replacingOccurrences(of: ">", with: "&gt;")
    res = res.replacingOccurrences(of: "\"", with: "&quot;")
    res = res.replacingOccurrences(of: "'", with: "&apos;")
    return res
  }

  private func wrapInSSML(_ text: String) -> String {
    return "<?xml version=\"1.0\"?>\n<speak>\(text)</speak>"
  }

  private func sanitizeSSML(_ ssml: String) -> String {
    var res = ssml
    #if os(macOS)
      if #available(macOS 26.0, *) {
      } else {
        res = res.replacingOccurrences(of: "<p>", with: "", options: .caseInsensitive)
        res = res.replacingOccurrences(of: "</p>", with: " ", options: .caseInsensitive)
        res = res.replacingOccurrences(of: "<s>", with: "", options: .caseInsensitive)
        res = res.replacingOccurrences(of: "</s>", with: " ", options: .caseInsensitive)
        ttsLogger.debug("Stripped SSML <p> and <s> tags for macOS < 26 bug")
      }
    #endif
    return res
  }

  private class SSMLValidationDelegate: NSObject, XMLParserDelegate {
    var hasValidStructure = false
    private var foundSpeakStart = false
    private var foundSpeakEnd = false

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
      attributes attributeDict: [String: String] = [:]
    ) {
      if elementName == "speak" {
        foundSpeakStart = true
      }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
      if elementName == "speak" {
        foundSpeakEnd = true
      }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
      hasValidStructure = foundSpeakStart && foundSpeakEnd
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
      hasValidStructure = false
    }
  }

  private func synthesizeInternal(
    text: String,
    voiceIdentifier: String?,
    onBuffer: @escaping (Data, AudioFormat) -> Void
  ) async throws {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      ttsLogger.info("Skipping synthesis of empty text")
      return
    }

    let utterance: AVSpeechUtterance

    if isValidSSML(trimmedText) {
      ttsLogger.info("Attempting SSML synthesis on valid input")

      var ssmlText = trimmedText
      if trimmedText.lowercased().hasPrefix("<speak") {
        ssmlText = "<?xml version=\"1.0\"?>\n" + trimmedText
      }
      ssmlText = sanitizeSSML(ssmlText)

      if let ssmlUtterance = AVSpeechUtterance(ssmlRepresentation: ssmlText) {
        utterance = ssmlUtterance
        ttsLogger.debug("SSML parsing succeeded")
      } else {
        ttsLogger.notice("SSML parsing failed, falling back to plain text wrapper")
        let escapedText = escapeXMLCharacters(trimmedText)
        let wrappedSSML = wrapInSSML(escapedText)
        utterance = AVSpeechUtterance(ssmlRepresentation: wrappedSSML)!
      }
    } else {
      ttsLogger.info("Wrapping plain text in SSML to prevent auto-detection")
      // wrap plain text in SSML to prevent AVSpeechUtterance from auto-detecting SSML
      // which always tries to parse input text as SSML if it starts with an XML tag
      let escapedText = escapeXMLCharacters(trimmedText)
      let wrappedSSML = wrapInSSML(escapedText)
      utterance = AVSpeechUtterance(ssmlRepresentation: wrappedSSML)!
    }

    let voiceIDToUse = resolveVoiceIdentifier(voiceIdentifier)

    if let voiceID = voiceIDToUse {
      if let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
        utterance.voice = voice
        ttsLogger.info("Voice identifier: \(voice.identifier)")
      } else {
        ttsLogger.notice("Voice '\(voiceID)' not found, using system default")
      }
    }

    if let setVoice = utterance.voice {
      ttsLogger.debug("Utterance voice identifier: \(setVoice.identifier)")
    } else {
      ttsLogger.notice("Utterance voice is nil")
    }

    let startTime = Date()
    var bufferCount = 0
    var totalBytes = 0
    var audioFormat: AudioFormat?

    return try await withCheckedThrowingContinuation { continuation in
      var hasResumed = false

      synthesizer.write(
        utterance,
        toBufferCallback: { [weak self] buffer in
          guard let self = self else { return }
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

          bufferCount += 1
          ttsLogger.debug("Received buffer #\(bufferCount): \(pcmBuffer.frameLength) frames")

          if audioFormat == nil && pcmBuffer.frameLength > 0 {
            audioFormat = self.detectAudioFormat(from: pcmBuffer)
          }

          if let data = self.convertBufferToData(pcmBuffer), !data.isEmpty {
            let format = audioFormat ?? AudioFormat.commonFormat
            totalBytes += data.count
            onBuffer(data, format)
          }

          // check if this is the last buffer (frameLength == 0 indicates end)
          if pcmBuffer.frameLength == 0 && !hasResumed {
            hasResumed = true

            let duration = Date().timeIntervalSince(startTime)
            Task {
              await self.metricsCollector.recordModelProcessing(
                bytes: totalBytes,
                duration: duration,
                serviceType: .tts
              )
            }

            ttsLogger.info(
              "Synthesis complete: \(bufferCount) buffers, \(totalBytes) bytes in \(String(format: "%.3f", duration))s")
            continuation.resume()
          }
        })

      // if no empty buffer is received, wait a bit and return what we have
      DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
        if !hasResumed {
          hasResumed = true
          ttsLogger.notice("Synthesis timeout")
          continuation.resume()
        }
      }
    }
  }

  private func resolveVoiceIdentifier(_ voiceIdentifier: String?) -> String? {
    if let voiceID = voiceIdentifier {
      return voiceID
    }

    let savedDefaultVoice = UserDefaults.standard.string(forKey: SettingsManager.userDefaultsKeyDefaultTTSVoice)

    if let savedVoice = savedDefaultVoice, !savedVoice.isEmpty {
      ttsLogger.info("Using saved default voice: \(savedVoice)")
      return savedVoice
    }
    return nil
  }

  private func detectAudioFormat(from buffer: AVAudioPCMBuffer) -> AudioFormat {
    let format = buffer.format
    let rate = Int(format.sampleRate)
    let channels = Int(format.channelCount)

    let width: Int
    if format.commonFormat == .pcmFormatFloat32 {
      width = 2  // Float32 converted to Int16
    } else {
      width = Int(format.streamDescription.pointee.mBytesPerFrame) / channels
    }

    ttsLogger.info("Audio format: \(rate) Hz, \(width) bytes/sample, \(channels) channel(s)")
    return AudioFormat(rate: rate, width: width, channels: channels)
  }

  func generateSilence(duration: TimeInterval, format: AudioFormat) -> Data {
    let sampleRate = format.rate
    let channels = format.channels
    let bytesPerSample = format.width
    let frameCount = Int(Double(sampleRate) * duration)
    let totalBytes = frameCount * channels * bytesPerSample
    return Data(count: totalBytes)
  }

  func extractCompleteSentence(from text: String) -> (sentence: String, remaining: String)? {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }

    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = trimmedText

    var firstSentenceRange: Range<String.Index>?
    tokenizer.enumerateTokens(in: trimmedText.startIndex..<trimmedText.endIndex) { tokenRange, _ in
      firstSentenceRange = tokenRange
      return false
    }

    if let range = firstSentenceRange {
      let sentence = String(trimmedText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      let remaining = String(trimmedText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !sentence.isEmpty {
        return (sentence, remaining)
      }
    }

    return nil
  }

  func synthesizeWithCallback(
    text: String,
    voiceIdentifier: String?,
    onAudioBuffer: @escaping (Data, AudioFormat) -> Void
  ) async throws {
    try await synthesizeInternal(text: text, voiceIdentifier: voiceIdentifier, onBuffer: onAudioBuffer)
  }
}

class SSMLChunker: NSObject, XMLParserDelegate {
  private var speakAttributes: [String: String] = [:]
  private var currentDepth = 0
  private var currentElementString = ""
  private var isCapturing = false
  private(set) var chunks: [String] = []

  func chunkSSML(_ ssml: String) -> [String] {
    speakAttributes = [:]
    currentDepth = 0
    currentElementString = ""
    isCapturing = false
    chunks = []

    guard let data = ssml.data(using: .utf8) else {
      return []
    }

    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()

    return chunks
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    if currentDepth == 0 && elementName == "speak" {
      speakAttributes = attributeDict
    } else if currentDepth == 1 {
      isCapturing = true
      currentElementString = "<\(elementName)"
      for (key, value) in attributeDict {
        currentElementString += " \(key)=\"\(value)\""
      }
      currentElementString += ">"
    } else if isCapturing {
      currentElementString += "<\(elementName)"
      for (key, value) in attributeDict {
        currentElementString += " \(key)=\"\(value)\""
      }
      currentElementString += ">"
    }
    currentDepth += 1
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
  ) {
    currentDepth -= 1

    if currentDepth == 1 && isCapturing {
      currentElementString += "</\(elementName)>"

      var chunk = "<speak"
      for (key, value) in speakAttributes {
        chunk += " \(key)=\"\(value)\""
      }
      chunk += ">"
      chunk += currentElementString
      chunk += "</speak>"
      chunks.append(chunk)

      isCapturing = false
      currentElementString = ""
    } else if isCapturing {
      currentElementString += "</\(elementName)>"
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if isCapturing {
      currentElementString += string
    }
  }
}
