import AVFoundation
import Foundation
import NaturalLanguage

/// Text-to-Speech service over Wyoming protocol.
class TTSService {
  private static let programName: String =
    (Bundle.main.infoDictionary?["CFBundleName"] as? String
    ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
    ?? "PomumD")
    .replacingOccurrences(of: " ", with: "-")

  private let synthesizer: AVSpeechSynthesizer
  private let metricsCollector: MetricsCollector
  private let settingsManager: SettingsManager

  init(metricsCollector: MetricsCollector, settingsManager: SettingsManager) {
    self.synthesizer = AVSpeechSynthesizer()
    self.metricsCollector = metricsCollector
    self.settingsManager = settingsManager
  }

  deinit {
    synthesizer.stopSpeaking(at: .immediate)
  }

  /// Returns all available TTS voices on the device.
  ///
  /// - Returns: Array of Voice models with quality information
  static func getAvailableVoices() -> [Voice] {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    return voices.map { Voice(from: $0) }
  }

  /// Returns Wyoming protocol service information for TTS capabilities.
  func getServiceInfo() -> [TTSProgram] {
    let voices = Self.getAvailableVoices()

    guard !voices.isEmpty else {
      return []
    }

    let ttsVoices = voices.map { voice in
      TTSVoice(
        name: voice.id,
        attribution: Attribution.apple,
        installed: true,
        description: voice.id,
        version: nil,
        languages: [voice.language],
        speakers: nil,
      )
    }

    let ttsProgram = TTSProgram(
      name: Self.programName,
      attribution: Attribution.pomumd,
      installed: true,
      description: "Wyoming Text-to-Speech using iOS AVSpeechSynthesizer",
      version: nil,
      voices: ttsVoices,
      supportsSynthesizeStreaming: true,
    )

    return [ttsProgram]
  }

  /// Synthesizes text to audio in non-streaming mode.
  ///
  /// - Parameters:
  ///   - text: Plain text or SSML to synthesize
  ///   - voiceIdentifier: Voice ID or language code, or nil for default
  /// - Returns: Complete audio data and format
  /// - Throws: Error if synthesis fails
  func synthesize(text: String, voiceIdentifier: String?) async throws -> (data: Data, format: AudioFormat) {
    var accumulated = Data()
    var capturedFormat: AudioFormat?

    try await synthesizeInternal(text: text, voiceIdentifier: voiceIdentifier) { data, format in
      accumulated.append(data)
      capturedFormat = format
    }

    return (data: accumulated, format: capturedFormat ?? AudioFormat.commonFormat)
  }

  // MARK: - SSML Handling

  private func convertBufferToData(_ buf: AVAudioPCMBuffer) -> Data? {
    return try? AudioBufferConverter.convertToData(buf)
  }

  /// Validates if text is well-formed SSML.
  ///
  /// Checks for XML structure and required `<speak>` root element.
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

    // check if input looks like an XML tag
    if trimmedText.hasPrefix("<") && trimmedText.contains(">") {
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
        ttsLogger.info("Text starts with XML tag but is not valid SSML, wrapping to prevent auto-detection")
        let escapedText = escapeXMLCharacters(trimmedText)
        let wrappedSSML = wrapInSSML(escapedText)
        utterance = AVSpeechUtterance(ssmlRepresentation: wrappedSSML)!
      }
    } else {
      ttsLogger.info("Processing as plain text")
      utterance = AVSpeechUtterance(string: trimmedText)
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

    utterance.prefersAssistiveTechnologySettings = settingsManager.defaultTTSPrefersAssistiveTechnologySettings
    utterance.rate = Float(settingsManager.defaultTTSRate)
    utterance.pitchMultiplier = Float(settingsManager.defaultTTSPitch)
    ttsLogger.debug(
      "Utterance parameters: rate=\(settingsManager.defaultTTSRate), pitch=\(settingsManager.defaultTTSPitch), pause=\(settingsManager.defaultTTSPause)s, assistive=\(settingsManager.defaultTTSPrefersAssistiveTechnologySettings)"
    )

    if let setVoice = utterance.voice {
      ttsLogger.debug("Utterance voice identifier: \(setVoice.identifier)")
    } else {
      ttsLogger.notice("Utterance voice is nil")
    }

    let startTime = Date()
    var bufferCount = 0
    var totalBytes = 0
    var audioFormat: AudioFormat?

    let baseTimeout = settingsManager.defaultTTSSynthesisTimeout
    let calculatedTimeout = Double(baseTimeout) + Double(trimmedText.count) * 0.05  // 0.05 seconds per character
    ttsLogger.debug(
      "Synthesis timeout: \(String(format: "%d", baseTimeout))+\(String(trimmedText.count))*0.05=\(String(format: "%.2f", calculatedTimeout))s"
    )

    return try await withCheckedThrowingContinuation { continuation in
      var hasResumed = false

      synthesizer.write(
        utterance,
        toBufferCallback: { [weak self] buffer in
          guard let self = self else { return }
          guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

          bufferCount += 1
          #if DEBUG
            ttsLogger.debug("Received buffer #\(bufferCount): \(pcmBuffer.frameLength) frames")
          #endif

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
            self.metricsCollector.recordModelProcessing(
              bytes: totalBytes,
              duration: duration,
              serviceType: .tts
            )

            ttsLogger.info(
              "Synthesis complete: \(bufferCount) buffers, \(totalBytes) bytes in \(String(format: "%.3f", duration))s")
            DispatchQueue.global(qos: .userInitiated).async {
              continuation.resume()
            }
          }
        })

      // if no empty buffer is received, wait for calculated timeout and return what we have
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + calculatedTimeout) {
        if !hasResumed {
          hasResumed = true
          ttsLogger.notice("Synthesis timeout after \(String(format: "%.1f", calculatedTimeout))s")
          continuation.resume()
        }
      }
    }
  }

  // MARK: - Helper Methods

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
    let audioFormat = AudioBufferConverter.detectFormat(from: buffer)
    ttsLogger.info("Audio format: \(audioFormat.description)")
    return audioFormat
  }

  func generateSilence(duration: TimeInterval, format: AudioFormat) -> Data {
    let sampleRate = format.rate
    let channels = format.channels
    let bytesPerSample = format.width
    let frameCount = sampleRate * UInt32(duration)
    let totalBytes = frameCount * channels * bytesPerSample
    return Data(count: Int(totalBytes))
  }

  /// Extracts the first complete sentence from text for streaming synthesis.
  ///
  /// Uses NLTokenizer for natural sentence boundary detection.
  ///
  /// - Parameter text: Input text to tokenize
  /// - Returns: Tuple of (first sentence, remaining text), or nil if no complete sentence found
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

  /// Synthesizes text with streaming audio buffer callbacks.
  ///
  /// Used for streaming TTS where audio chunks are sent as they're generated.
  ///
  /// - Parameters:
  ///   - text: Plain text or SSML to synthesize
  ///   - voiceIdentifier: Voice ID or language code, or nil for default
  ///   - onAudioBuffer: Callback invoked for each audio buffer chunk
  /// - Throws: Error if synthesis fails
  func synthesizeWithCallback(
    text: String,
    voiceIdentifier: String?,
    onAudioBuffer: @escaping (Data, AudioFormat) -> Void
  ) async throws {
    try await synthesizeInternal(text: text, voiceIdentifier: voiceIdentifier, onBuffer: onAudioBuffer)
  }
}

// MARK: - SSML Chunker

/// Parses SSML documents and splits them into first-level child elements for streaming synthesis.
///
/// Preserves the `<speak>` root element attributes in each chunk for proper SSML structure.
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
