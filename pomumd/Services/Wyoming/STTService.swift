import AVFoundation
import Foundation
import Speech

class STTService {
  private static let programName: String = {
    let appName =
      (Bundle.main.infoDictionary?["CFBundleName"] as? String
      ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
      ?? "pomumd")
      .replacingOccurrences(of: " ", with: "-")
      .lowercased()
    return "\(appName)-wyoming-stt"
  }()

  private let metricsCollector: MetricsCollector

  init(metricsCollector: MetricsCollector) {
    self.metricsCollector = metricsCollector
  }

  static func getLanguages() -> [String] {
    return SFSpeechRecognizer.supportedLocales().map { $0.identifier }
  }

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
      name: Self.programName,
      languages: languages,
      attribution: Attribution.apple,
      installed: true,
      description: "Wyoming Speech-to-Text using iOS SFSpeechRecognizer",
      version: nil
    )

    let asrProgram = ASRProgram(
      name: Self.programName,
      description: "Wyoming Speech-to-Text using iOS SFSpeechRecognizer",
      installed: true,
      attribution: Attribution.apple,
      models: [asrModel],
      supportsTranscriptStreaming: true
    )

    return [asrProgram]
  }

  func transcribe(
    audioData: Data,
    sampleRate: Int,
    channels: Int,
    language: String?,
    onPartialResult: ((String) -> Void)? = nil
  ) async throws -> String {
    let startTime = Date()
    let audioBytes = audioData.count

    sttLogger.info("Transcribing audio: \(audioBytes) bytes, \(sampleRate) Hz, \(channels) channels")

    let languageToUse = resolveLanguage(language)

    // use different API based on platform version
    // iOS/iPadOS/macOS/visionOS 26.0+: SpeechAnalyzer
    // Fallback: legacy SFSpeechRecognizer
    let result: String
    if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
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
    await metricsCollector.recordModelProcessing(
      bytes: audioBytes,
      duration: duration,
      serviceType: .stt
    )
    sttLogger.info("Transcription complete: \(audioBytes) bytes in \(String(format: "%.3f", duration))s")

    return result
  }

  @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
  private func transcribeWithSpeechAnalyzer(
    audioData: Data,
    sampleRate: Int,
    channels: Int,
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

    // convert audio data to PCM buffer in source format
    guard let sourcePCMBuffer = createPCMBuffer(from: audioData, format: sourceFormat) else {
      throw STTError.invalidAudioData
    }
    sttLogger.debug("Created source PCM buffer: \(sourcePCMBuffer.frameLength) frames")

    // resample if needed
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

    // input audio in a task
    Task {
      let input = AnalyzerInput(buffer: finalBuffer)
      inputBuilder.yield(input)
      inputBuilder.finish()
      sttLogger.debug("Audio input finished")
    }

    // collect transcription results in a task
    var transcription = ""
    let resultsTask = Task {
      do {
        for try await result in transcriber.results {
          transcription = String(result.text.characters)
          sttLogger.info("Received transcription: '\(transcription)'")
          // call callback for streaming partial results
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

    // wait for results task to complete
    try await resultsTask.value

    sttLogger.info("Transcription complete: '\(transcription)'")
    return transcription
  }

  private func transcribeWithSFSpeechRecognizer(
    audioData: Data,
    sampleRate: Int,
    channels: Int,
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

          // call callback for streaming partial results
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

  private func resampleAudio(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
      sttLogger.error("Failed to create audio converter")
      return nil
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
      sttLogger.error("Failed to create output buffer")
      return nil
    }

    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
    if status == .error {
      sttLogger.error("Conversion error: \(error?.localizedDescription ?? "unknown")")
      return nil
    }

    return outputBuffer
  }

  private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frameCount = data.count / 2

    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else {
      return nil
    }

    buffer.frameLength = AVAudioFrameCount(frameCount)

    guard let channelData = buffer.int16ChannelData else {
      return nil
    }

    data.withUnsafeBytes { rawBufferPointer in
      guard let baseAddress = rawBufferPointer.baseAddress else { return }
      let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
      channelData[0].update(from: int16Pointer, count: frameCount)
    }

    return buffer
  }
}

enum STTError: Error {
  case invalidAudioData
  case transcriptionFailed
  case unsupportedLanguage
  case recognizerUnavailable
}
