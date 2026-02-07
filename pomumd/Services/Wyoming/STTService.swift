import AVFoundation
import Foundation
import Speech

/// Speech-to-Text service over Wyoming protocol.
class STTService {
  private static let programName: String =
    (Bundle.main.infoDictionary?["CFBundleName"] as? String
    ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
    ?? "PomumD")
    .replacingOccurrences(of: " ", with: "-")

  private let metricsCollector: MetricsCollector

  init(metricsCollector: MetricsCollector) {
    self.metricsCollector = metricsCollector
  }

  /// Returns all supported language identifiers for speech recognition.
  ///
  /// - Returns: Array of BCP 47 language codes (e.g., "en-US", "zh-CN")
  static func getLanguages() -> [String] {
    return SFSpeechRecognizer.supportedLocales().map { $0.identifier }
  }

  /// Resolves the language to use for transcription.
  ///
  /// Priority: provided language > saved default > nil (system default)
  private func resolveLanguage(_ providedLanguage: String?) -> String? {
    if let lang = providedLanguage {
      sttLogger.info("Using specified language: \(lang)")
      return lang
    }

    let savedDefaultLanguage = UserDefaults.standard.string(forKey: SettingsManager.userDefaultsKeyDefaultSTTLanguage)
    if let savedLang = savedDefaultLanguage, !savedLang.isEmpty {
      sttLogger.info("Using saved default language: \(savedLang)")
      return savedLang
    }
    return nil
  }

  func getServiceInfo() -> [ASRProgram] {
    let languages = Self.getLanguages()

    guard !languages.isEmpty else {
      return []
    }

    let asrModel = ASRModel(
      name: "SFSpeechRecognizer",
      attribution: Attribution.apple,
      installed: true,
      description: "Wyoming Speech-to-Text using iOS SFSpeechRecognizer",
      version: nil,
      languages: languages,
    )

    let asrProgram = ASRProgram(
      name: Self.programName,
      attribution: Attribution.pomumd,
      installed: true,
      description: "Wyoming Speech-to-Text using iOS SFSpeechRecognizer",
      version: nil,
      models: [asrModel],
      supportsTranscriptStreaming: true,
    )

    return [asrProgram]
  }

  /// Transcribes audio data to text using on-device speech recognition.
  ///
  /// Automatically selects the best available API based on platform version.
  ///
  /// - Parameters:
  ///   - audioData: Raw PCM audio samples (Int16 format)
  ///   - sampleRate: Sample rate in Hz (e.g., 16000)
  ///   - channels: Number of audio channels (1=mono, 2=stereo)
  ///   - language: BCP 47 language code, or nil for default
  ///   - onPartialResult: Optional callback for streaming partial transcriptions
  /// - Returns: Final transcribed text
  /// - Throws: STTError if transcription fails
  func transcribe(
    audioData: Data,
    sampleRate: UInt32,
    channels: UInt32,
    language: String?,
    onPartialResult: ((String) -> Void)? = nil
  ) async throws -> String {
    let startTime = Date()
    let audioBytes = audioData.count

    sttLogger.info("Transcribing audio: \(audioBytes) bytes, \(sampleRate) Hz, \(channels) channels")

    let languageToUse = resolveLanguage(language)

    // use different API based on platform version
    // iOS/iPadOS/macOS 26.0+: SpeechAnalyzer
    // Fallback: legacy SFSpeechRecognizer
    let result: String
    if #available(iOS 26.0, macOS 26.0, *) {
      sttLogger.debug("Using SpeechAnalyzer API")
      result = try await transcribeWithSpeechAnalyzer(
        audioData: audioData, sampleRate: sampleRate, channels: channels, language: languageToUse,
        onPartialResult: onPartialResult)
    } else {
      sttLogger.debug("Using legacy SFSpeechRecognizer API")
      result = try await transcribeWithSFSpeechRecognizer(
        audioData: audioData, sampleRate: sampleRate, channels: channels, language: languageToUse,
        onPartialResult: onPartialResult)
    }

    let duration = Date().timeIntervalSince(startTime)
    metricsCollector.recordModelProcessing(
      bytes: audioBytes,
      duration: duration,
      serviceType: .stt
    )
    sttLogger.info("Transcription complete: \(audioBytes) bytes in \(String(format: "%.3f", duration))s")

    return result
  }

  /// Transcribes audio using the modern SpeechAnalyzer API (iOS 26+).
  @available(iOS 26.0, macOS 26.0, *)
  private func transcribeWithSpeechAnalyzer(
    audioData: Data,
    sampleRate: UInt32,
    channels: UInt32,
    language: String?,
    onPartialResult: ((String) -> Void)?
  ) async throws -> String {
    let requestedLocale = language != nil ? Locale(identifier: language!) : Locale.current
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      sttLogger.error("Language not supported: \(requestedLocale.identifier)")
      throw STTError.unsupportedLanguage
    }
    sttLogger.info("Using language: \(locale.identifier)")

    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

    // download assets on demand
    if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      sttLogger.debug("Downloading transcriber assets")
      try await installationRequest.downloadAndInstall()
      sttLogger.debug("Transcriber assets downloaded")
    }

    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

    guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw STTError.invalidAudioData
    }
    sttLogger.debug("Target format: \(targetFormat.sampleRate) Hz, \(targetFormat.channelCount) channels")

    guard let sourceFormat = AudioFormat(rate: sampleRate, width: 2, channels: channels).toAVAudioFormat() else {
      throw STTError.invalidAudioData
    }

    guard let sourcePCMBuffer = createPCMBuffer(from: audioData, format: sourceFormat) else {
      throw STTError.invalidAudioData
    }
    sttLogger.debug("Created source PCM buffer: \(sourcePCMBuffer.frameLength) frames")

    let finalBuffer: AVAudioPCMBuffer
    if sourceFormat.sampleRate != targetFormat.sampleRate || sourceFormat.channelCount != targetFormat.channelCount {
      sttLogger.info("Resampling from \(sourceFormat.sampleRate) Hz to \(targetFormat.sampleRate) Hz")
      guard let resampledBuffer = resampleAudio(buffer: sourcePCMBuffer, to: targetFormat) else {
        throw STTError.invalidAudioData
      }
      finalBuffer = resampledBuffer
      sttLogger.debug("Resampled buffer: \(finalBuffer.frameLength) frames")
    } else {
      finalBuffer = sourcePCMBuffer
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    Task {
      let input = AnalyzerInput(buffer: finalBuffer)
      inputBuilder.yield(input)
      inputBuilder.finish()
      sttLogger.debug("Audio input finished")
    }

    var transcription = ""
    let resultsTask = Task {
      do {
        for try await result in transcriber.results {
          transcription = String(result.text.characters)
          sttLogger.info("Received transcription: '\(transcription)'")
          onPartialResult?(transcription)
        }
      } catch {
        sttLogger.error("Transcription error: \(error)")
        throw error
      }
    }

    let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
    if let lastSampleTime = lastSampleTime {
      try await analyzer.finalizeAndFinish(through: lastSampleTime)
    } else {
      await analyzer.cancelAndFinishNow()
    }

    try await resultsTask.value

    sttLogger.info("Transcription complete: '\(transcription)'")
    return transcription
  }

  /// Transcribes audio using the legacy SFSpeechRecognizer API (iOS 16+).
  private func transcribeWithSFSpeechRecognizer(
    audioData: Data,
    sampleRate: UInt32,
    channels: UInt32,
    language: String?,
    onPartialResult: ((String) -> Void)?
  ) async throws -> String {
    let locale: Locale
    if let lang = language {
      locale = Locale(identifier: lang)
    } else {
      locale = Locale.current
    }

    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      sttLogger.error("Speech recognizer not available for locale: \(locale.identifier)")
      throw STTError.recognizerUnavailable
    }

    guard recognizer.isAvailable else {
      sttLogger.error("Speech recognizer not available")
      throw STTError.recognizerUnavailable
    }
    sttLogger.info("Using language: \(locale.identifier)")

    guard let sourceFormat = AudioFormat(rate: sampleRate, width: 2, channels: channels).toAVAudioFormat() else {
      throw STTError.invalidAudioData
    }

    guard let audioBuffer = createPCMBuffer(from: audioData, format: sourceFormat) else {
      throw STTError.invalidAudioData
    }
    sttLogger.debug("Created audio buffer: \(audioBuffer.frameLength) frames")

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.append(audioBuffer)
    request.endAudio()

    return try await withCheckedThrowingContinuation { continuation in
      recognizer.recognitionTask(with: request) { result, error in
        if let error = error {
          sttLogger.error("Recognition error: \(error)")
          continuation.resume(throwing: STTError.transcriptionFailed)
          return
        }

        if let result = result {
          let transcription = result.bestTranscription.formattedString

          if !result.isFinal {
            sttLogger.info("Received partial transcription: '\(transcription)'")
            onPartialResult?(transcription)
          }

          if result.isFinal {
            sttLogger.info("Transcription complete: '\(transcription)'")
            continuation.resume(returning: transcription)
          }
        }
      }
    }
  }

  // MARK: - Audio Conversion

  private func resampleAudio(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    return try? AudioBufferConverter.resample(buffer, to: targetFormat)
  }

  private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    return try? AudioBufferConverter.convertToBuffer(from: data, format: format)
  }
}

enum STTError: Error {
  case invalidAudioData
  case transcriptionFailed
  case unsupportedLanguage
  case recognizerUnavailable
}
