import Combine
import Foundation
import Network

enum ServiceType {
  case info
  case tts
  case stt
  case unknown
}

class WyomingServer: ObservableObject {
  @Published var isRunning: Bool = false
  let port: UInt16

  private let metricsCollector: MetricsCollector
  private let settingsManager: SettingsManager
  private var listener: NWListener?
  private var connections: [ConnectionHandler] = []

  init(port: UInt16 = 10200, metricsCollector: MetricsCollector, settingsManager: SettingsManager) {
    self.port = port
    self.metricsCollector = metricsCollector
    self.settingsManager = settingsManager
  }

  func start() throws {
    guard !isRunning else { return }

    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.serviceClass = NWParameters.ServiceClass.interactiveVoice

    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw NSError(domain: "WyomingServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
    }

    listener = try NWListener(using: params, on: port)

    listener?.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        switch state {
        case .ready:
          self?.isRunning = true
        case .failed(let error):
          wyomingServerLogger.error("Wyoming server failed: \(error)")
          self?.isRunning = false
          self?.metricsCollector.recordConnectionError()
        case .cancelled:
          self?.isRunning = false
        default:
          break
        }
      }
    }

    listener?.newConnectionHandler = { [weak self] conn in
      self?.handleConnection(conn)
    }

    listener?.start(queue: .global(qos: .userInitiated))
  }

  func stop() {
    listener?.cancel()
    listener = nil

    // close all connections
    connections.forEach { $0.close() }
    connections.removeAll()
  }

  private func handleConnection(_ connection: NWConnection) {
    let handler = ConnectionHandler(
      connection: connection,
      metricsCollector: metricsCollector,
      settingsManager: settingsManager
    )

    handler.onClose = { [weak self] in
      DispatchQueue.main.async {
        self?.connections.removeAll { $0 === handler }
      }
    }

    connections.append(handler)

    handler.start()
  }
}

class ConnectionHandler {
  private let connection: NWConnection
  private let metricsCollector: MetricsCollector
  private let settingsManager: SettingsManager
  private lazy var ttsService: TTSService = TTSService(
    metricsCollector: metricsCollector,
    settingsManager: settingsManager,
  )
  private lazy var sttService: STTService = STTService(metricsCollector: metricsCollector)

  private var receiveBuffer = Data()
  private var isTranscribing = false

  private var audioBuffer = Data()
  private var transcribeLanguage: String?
  private var audioSampleRate: UInt32 = 16000
  private var audioChannels: UInt32 = 1
  private var audioWidth: UInt32 = 2

  // TTS streaming state
  private var isSynthesizingStreaming = false
  private var synthesizeTextBuffer = ""
  private var synthesizeVoiceIdentifier: String?
  private var hasStartedAudioStream = false
  private var pendingSynthesisTask: Task<Void, Never>?
  private var currentAudioFormat: AudioFormat?
  private var isSSMLMode = false

  private var streamingTTSStartTime: Date?
  private var nonStreamingTTSStartTime: Date?
  private var sttStartTime: Date?
  private var isClosed = false

  var onClose: (() -> Void)?

  private func parseEvent<T: WyomingEvent>(_ message: WyomingMessage, as type: T.Type) -> T? {
    do {
      return try T.fromMessage(message)
    } catch {
      wyomingServerLogger.error("Failed to parse \(T.self): \(error)")
      metricsCollector.recordConnectionError()
      close()
      return nil
    }
  }

  private func extractVoiceIdentifier(from voice: SynthesizeVoice?) -> String? {
    guard let voice = voice else {
      wyomingServerLogger.debug("No voice specified, using default")
      return nil
    }

    if let name = voice.name {
      wyomingServerLogger.debug("Specified voice name: '\(name)'")
      return name
    } else if let language = voice.language {
      wyomingServerLogger.debug("Specified voice language: '\(language)'")
      return language
    }

    return nil
  }

  private func sendMessage(_ message: WyomingMessage) {
    let data = WyomingProtocol.serializeMessage(message)
    sendData(data)
  }

  /// Reset streaming synthesis state
  private func resetStreamingState() {
    isSynthesizingStreaming = false
    synthesizeTextBuffer = ""
    synthesizeVoiceIdentifier = nil
    hasStartedAudioStream = false
    pendingSynthesisTask = nil
    currentAudioFormat = nil
    isSSMLMode = false
  }

  /// Process audio buffer from streaming synthesis callback
  private func processStreamingAudioBuffer(audioData: Data, audioFormat: AudioFormat) {
    if currentAudioFormat == nil {
      currentAudioFormat = audioFormat
    }
    sendAudioChunk(audioData, format: audioFormat)
  }

  /// Quick check if text looks like SSML (for streaming detection),
  /// just checks prefix and closing tag, doesn't validate XML structure
  private func looksLikeSSML(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()

    guard lowercased.hasPrefix("<?xml") || lowercased.hasPrefix("<speak") else {
      return false
    }
    guard lowercased.contains("</speak>") else {
      return false
    }

    return true
  }

  init(connection: NWConnection, metricsCollector: MetricsCollector, settingsManager: SettingsManager) {
    self.connection = connection
    self.metricsCollector = metricsCollector
    self.settingsManager = settingsManager

    metricsCollector.recordConnection()
    metricsCollector.incrementActiveConnections()
  }

  private func sendData(_ data: Data) {
    connection.send(content: data, completion: .contentProcessed { _ in })

    metricsCollector.recordNetworkTraffic(bytesIn: 0, bytesOut: UInt64(data.count))
  }

  func start() {
    connection.start(queue: .global(qos: .userInitiated))

    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.receiveMessage()
      case .failed, .cancelled:
        self?.close()
        self?.onClose?()
      default:
        break
      }
    }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true

    metricsCollector.decrementActiveConnections()
    connection.cancel()
  }

  private func sendInfo() async {
    let ttsPrograms = ttsService.getServiceInfo()
    let asrPrograms = sttService.getServiceInfo()

    let message = InfoEvent(asr: asrPrograms, tts: ttsPrograms).toMessage()
    sendMessage(message)
  }

  private func receiveMessage() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }

      networkLogger.debug("Rx: \(data?.count ?? 0), isComplete: \(isComplete), error: \(String(describing: error))")

      if let data = data, !data.isEmpty {
        self.receiveBuffer.append(data)
        networkLogger.debug("len(buffer)=\(self.receiveBuffer.count)")

        self.metricsCollector.recordNetworkTraffic(bytesIn: UInt64(data.count), bytesOut: 0)

        self.processBuffer()
      }

      if isComplete {
        networkLogger.debug("Connection closed by client")
        self.close()
        self.onClose?()
        return
      }

      // continue receiving
      self.receiveMessage()
    }
  }

  private func processBuffer() {
    while let message = WyomingProtocol.parseMessage(from: self.receiveBuffer) {
      wyomingServerLogger.debug("Parsed message type: \(message.type)")
      let messageSize = message.messageSize
      if messageSize > 0 && messageSize <= self.receiveBuffer.count {
        self.receiveBuffer.replaceSubrange(0..<messageSize, with: Data())
      }

      self.handleMessage(message)
    }
  }

  private func handleMessage(_ message: WyomingMessage) {
    wyomingServerLogger.debug("Received message type: \(message.type)")

    switch message.type {
    case .describe:
      handleDescribe(message)
    case .synthesize:
      handleSynthesize(message)
    case .transcribe:
      handleTranscribe(message)
    case .audioStart:
      handleAudioStart(message)
    case .audioChunk:
      handleAudioChunk(message)
    case .audioStop:
      handleAudioStop(message)
    case .synthesizeStart:
      handleSynthesizeStart(message)
    case .synthesizeChunk:
      handleSynthesizeChunk(message)
    case .synthesizeStop:
      handleSynthesizeStop(message)
    default:
      break
    }
  }

  private func handleDescribe(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleDescribe called")
    Task {
      await sendInfo()
    }
  }

  private func handleSynthesize(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesize called")

    // ignore non-streaming synthesize events if streaming is active
    if isSynthesizingStreaming {
      return
    }

    guard let synthesizeEvent = parseEvent(message, as: SynthesizeEvent.self) else {
      return
    }

    wyomingServerLogger.info("Synthesizing text: '\(synthesizeEvent.text)'")

    let voiceIdentifier = extractVoiceIdentifier(from: synthesizeEvent.voice)

    nonStreamingTTSStartTime = Date()

    Task {
      wyomingServerLogger.debug("Starting synthesis task...")
      do {
        let (audioData, audioFormat) = try await ttsService.synthesize(
          text: synthesizeEvent.text, voiceIdentifier: voiceIdentifier)

        sendAudioStream(audioData, format: audioFormat)
        wyomingServerLogger.debug("Sent audio stream")
      } catch {
        wyomingServerLogger.error("Synthesis error: \(error)")
        metricsCollector.recordConnectionError()
        close()
      }
    }
  }

  private func handleSynthesizeStart(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesizeStart called")

    guard let synthesizeStartEvent = parseEvent(message, as: SynthesizeStartEvent.self) else {
      return
    }

    let voiceIdentifier = extractVoiceIdentifier(from: synthesizeStartEvent.voice)

    streamingTTSStartTime = Date()
    isSynthesizingStreaming = true
    synthesizeTextBuffer = ""
    synthesizeVoiceIdentifier = voiceIdentifier
    hasStartedAudioStream = false
    pendingSynthesisTask = nil
    currentAudioFormat = nil
    isSSMLMode = false
    wyomingServerLogger.debug("Streaming synthesis started")
  }

  private func handleSynthesizeChunk(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesizeChunk called")

    guard isSynthesizingStreaming else {
      wyomingServerLogger.info("Not in streaming synthesis mode")
      return
    }
    guard let synthesizeChunkEvent = parseEvent(message, as: SynthesizeChunkEvent.self) else {
      return
    }

    synthesizeTextBuffer += synthesizeChunkEvent.text
    wyomingServerLogger.debug(
      "Added chunk to buffer: '\(synthesizeChunkEvent.text)' (total buffer: \(synthesizeTextBuffer.count) chars)")

    if !isSSMLMode && looksLikeSSML(synthesizeTextBuffer) {
      isSSMLMode = true
      wyomingServerLogger.info("SSML detected in streaming buffer - will chunk by first-level nodes")
    }

    pendingSynthesisTask = Task {
      await processSentencesFromBuffer()
    }
  }

  private func processSentencesFromBuffer() async {
    if isSSMLMode {
      let trimmed = synthesizeTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let speakEndRange = trimmed.range(of: "</speak>", options: .caseInsensitive) else {
        wyomingServerLogger.debug("SSML incomplete, waiting for more chunks")
        return
      }

      let ssmlEndIndex = speakEndRange.upperBound
      let ssmlPortion = String(trimmed[..<ssmlEndIndex])
      let remainingText = String(trimmed[ssmlEndIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

      wyomingServerLogger.debug("Complete SSML detected, chunking by first-level nodes")
      let chunker = SSMLChunker()
      let chunks = chunker.chunkSSML(ssmlPortion)

      if chunks.isEmpty {
        wyomingServerLogger.info("No first-level child nodes found in SSML: '\(ssmlPortion)'")
        return
      }
      wyomingServerLogger.debug("Extracted \(chunks.count) SSML chunks")

      for (index, chunk) in chunks.enumerated() {
        wyomingServerLogger.debug("Synthesizing SSML chunk \(index + 1)/\(chunks.count): '\(chunk)'")
        do {
          try await ttsService.synthesizeWithCallback(
            text: chunk,
            voiceIdentifier: synthesizeVoiceIdentifier,
            onAudioBuffer: { [weak self] audioData, audioFormat in
              self?.processStreamingAudioBuffer(audioData: audioData, audioFormat: audioFormat)
            }
          )
        } catch {
          wyomingServerLogger.error("SSML chunk synthesis error: \(error)")
          metricsCollector.recordConnectionError()
          close()
        }
      }

      synthesizeTextBuffer = remainingText
      if !synthesizeTextBuffer.isEmpty && !looksLikeSSML(synthesizeTextBuffer) {
        isSSMLMode = false
        wyomingServerLogger.notice("Remaining text after SSML is plain text, switching to plain text mode")
      } else if !synthesizeTextBuffer.isEmpty {
        wyomingServerLogger.debug("Remaining text after SSML looks like SSML, staying in SSML mode")
      }
    } else {
      while let (sentence, remaining) = ttsService.extractCompleteSentence(from: synthesizeTextBuffer) {
        wyomingServerLogger.info("Synthesizing sentence: '\(sentence)'")
        synthesizeTextBuffer = remaining

        do {
          try await ttsService.synthesizeWithCallback(
            text: sentence,
            voiceIdentifier: synthesizeVoiceIdentifier,
            onAudioBuffer: { [weak self] audioData, audioFormat in
              self?.processStreamingAudioBuffer(audioData: audioData, audioFormat: audioFormat)
            }
          )

          // add pause between sentences
          if let format = currentAudioFormat, settingsManager.defaultTTSPause > 0 {
            let silence = ttsService.generateSilence(
              duration: TimeInterval(settingsManager.defaultTTSPause), format: format)
            sendAudioChunk(silence, format: format)
          }
        } catch {
          wyomingServerLogger.error("Sentence synthesis error: \(error)")
          metricsCollector.recordConnectionError()
          close()
        }
      }
    }
  }

  private func handleSynthesizeStop(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesizeStop called")

    guard isSynthesizingStreaming else {
      wyomingServerLogger.info("Not in streaming synthesis mode")
      return
    }
    guard parseEvent(message, as: SynthesizeStopEvent.self) != nil else {
      return
    }

    Task {
      await pendingSynthesisTask?.value
      wyomingServerLogger.debug("Pending synthesis task completed")

      var hadError = false
      if !synthesizeTextBuffer.isEmpty {
        if isSSMLMode {
          wyomingServerLogger.info("Synthesizing complete SSML document: '\(synthesizeTextBuffer)'")
        } else {
          wyomingServerLogger.info("Synthesizing remaining text: '\(synthesizeTextBuffer)'")
        }
        do {
          try await ttsService.synthesizeWithCallback(
            text: synthesizeTextBuffer,
            voiceIdentifier: synthesizeVoiceIdentifier,
            onAudioBuffer: { [weak self] audioData, audioFormat in
              self?.sendAudioChunk(audioData, format: audioFormat)
            }
          )
        } catch {
          wyomingServerLogger.error("Final synthesis error: \(error)")
          metricsCollector.recordConnectionError()
          hadError = true
        }
      }
      sendAudioStop()
      sendSynthesizeStopped()

      if let startTime = streamingTTSStartTime {
        let duration = Date().timeIntervalSince(startTime)
        metricsCollector.recordServiceProcessing(duration: duration, serviceType: .tts)
        streamingTTSStartTime = nil
      }

      resetStreamingState()

      if hadError {
        close()
      }
    }
  }

  private func sendAudioStream(_ data: Data, format: AudioFormat) {
    let startMessage = AudioStartEvent(format: format, timestamp: nil).toMessage()
    sendMessage(startMessage)

    let chunkSize = 2048
    var offset = 0

    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      let chunk = data.subdata(in: offset..<end)

      let chunkMessage = AudioChunkEvent(format: format, audio: chunk, timestamp: nil).toMessage()
      sendMessage(chunkMessage)

      offset = end
    }

    let stopMessage = AudioStopEvent(timestamp: nil).toMessage()
    sendMessage(stopMessage)

    if let startTime = nonStreamingTTSStartTime {
      let duration = Date().timeIntervalSince(startTime)
      metricsCollector.recordServiceProcessing(duration: duration, serviceType: .tts)
      nonStreamingTTSStartTime = nil
    }
  }

  private func handleTranscribe(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleTranscribe called")

    guard let transcribeEvent = parseEvent(message, as: TranscribeEvent.self) else {
      return
    }

    if let language = transcribeEvent.language {
      transcribeLanguage = language
      wyomingServerLogger.info("Specified language: '\(language)'")
    } else {
      transcribeLanguage = nil
      wyomingServerLogger.info("No language specified, using default")
    }

    sttStartTime = Date()

    isTranscribing = true
    audioBuffer = Data()
  }

  private func handleAudioStart(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioStart called")

    guard let audioStartEvent = parseEvent(message, as: AudioStartEvent.self) else {
      return
    }

    audioSampleRate = audioStartEvent.format.rate
    audioWidth = audioStartEvent.format.width
    audioChannels = audioStartEvent.format.channels
    wyomingServerLogger.debug(
      "audio-start: sample rate: \(audioSampleRate) Hz, width: \(audioWidth), channels: \(audioChannels)")
  }

  private func handleAudioChunk(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioChunk called")

    guard isTranscribing else { return }

    guard let audioChunkEvent = parseEvent(message, as: AudioChunkEvent.self) else {
      return
    }

    audioBuffer.append(audioChunkEvent.audio)
    wyomingServerLogger.debug("audio-chunk: \(audioChunkEvent.audio.count) bytes, total: \(audioBuffer.count) bytes")
  }

  private func handleAudioStop(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioStop called")

    guard isTranscribing else { return }

    if let audioStopEvent = parseEvent(message, as: AudioStopEvent.self),
      let timestamp = audioStopEvent.timestamp
    {
      wyomingServerLogger.debug("audio-stop: timestamp: \(timestamp) ms")
    }

    isTranscribing = false

    wyomingServerLogger.debug("Starting transcription with \(audioBuffer.count) bytes of audio")

    Task {
      do {
        sendTranscriptStart(language: transcribeLanguage)

        let text = try await sttService.transcribe(
          audioData: audioBuffer,
          sampleRate: audioSampleRate,
          channels: audioChannels,
          language: transcribeLanguage,
          onPartialResult: { [weak self] partialText in
            self?.sendTranscriptChunk(partialText)
          }
        )
        wyomingServerLogger.info("Transcription complete: '\(text)'")

        sendTranscript(text)
        sendTranscriptStop()

        if let startTime = sttStartTime {
          let duration = Date().timeIntervalSince(startTime)
          metricsCollector.recordServiceProcessing(duration: duration, serviceType: .stt)
          sttStartTime = nil
        }
      } catch {
        wyomingServerLogger.error("Transcription error: \(error)")
        metricsCollector.recordConnectionError()
        close()
      }
    }
  }

  private func sendTranscript(_ text: String) {
    let message = TranscriptEvent(text: text, language: nil).toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Transcript sent")
  }

  private func sendTranscriptStart(language: String?) {
    let message = TranscriptStartEvent(language: language).toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Transcript start sent")
  }

  private func sendTranscriptChunk(_ text: String) {
    let message = TranscriptChunkEvent(text: text, language: nil).toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Transcript chunk sent: '\(text)'")
  }

  private func sendTranscriptStop() {
    let message = TranscriptStopEvent().toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Transcript stop sent")
  }

  private func sendAudioChunk(_ audioData: Data, format: AudioFormat) {
    if isSynthesizingStreaming && !hasStartedAudioStream {
      let startMessage = AudioStartEvent(format: format, timestamp: nil).toMessage()
      sendMessage(startMessage)
      hasStartedAudioStream = true
      wyomingServerLogger.debug("Audio start sent (streaming)")
    }

    let message = AudioChunkEvent(format: format, audio: audioData, timestamp: nil).toMessage()
    sendMessage(message)
  }

  private func sendAudioStop() {
    let message = AudioStopEvent(timestamp: nil).toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Audio stop sent")
  }

  private func sendSynthesizeStopped() {
    let message = SynthesizeStoppedEvent().toMessage()
    sendMessage(message)
    wyomingServerLogger.debug("Synthesize stopped sent")
  }
}
