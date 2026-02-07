import Combine
import Foundation
import Network

enum ServiceType {
  case info
  case tts
  case stt
  case unknown
}

/// TCP server implementing Wyoming protocol for TTS and STT services.
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

// MARK: - TTS Streaming State

/// Manages TTS streaming session state and context.
///
/// Tracks text buffering, voice selection, and audio stream lifecycle for streaming synthesis.
enum TTSStreamingState: Equatable {
  case idle
  case streaming(StreamingContext)

  struct StreamingContext: Equatable {
    var textBuffer: String
    var voiceIdentifier: String?
    var audioStreamStarted: Bool
    var pendingTask: TaskIdentifier?
    var audioFormat: AudioFormat?
    var ssmlMode: Bool

    init(
      textBuffer: String = "",
      voiceIdentifier: String? = nil,
      audioStreamStarted: Bool = false,
      pendingTask: TaskIdentifier? = nil,
      audioFormat: AudioFormat? = nil,
      ssmlMode: Bool = false
    ) {
      self.textBuffer = textBuffer
      self.voiceIdentifier = voiceIdentifier
      self.audioStreamStarted = audioStreamStarted
      self.pendingTask = pendingTask
      self.audioFormat = audioFormat
      self.ssmlMode = ssmlMode
    }
  }

  struct TaskIdentifier: Equatable, Hashable {
    let id: UUID
  }

  // MARK: - State Transitions

  mutating func startStreaming(voiceIdentifier: String?) {
    self = .streaming(StreamingContext(voiceIdentifier: voiceIdentifier))
  }

  mutating func appendText(_ text: String) {
    guard case .streaming(var context) = self else { return }
    context.textBuffer += text
    self = .streaming(context)
  }

  mutating func updateTextBuffer(_ newBuffer: String) {
    guard case .streaming(var context) = self else { return }
    context.textBuffer = newBuffer
    self = .streaming(context)
  }

  mutating func setSSMLMode(_ enabled: Bool) {
    guard case .streaming(var context) = self else { return }
    context.ssmlMode = enabled
    self = .streaming(context)
  }

  mutating func markAudioStreamStarted(format: AudioFormat) {
    guard case .streaming(var context) = self else { return }
    context.audioStreamStarted = true
    context.audioFormat = format
    self = .streaming(context)
  }

  mutating func setPendingTask(_ taskId: TaskIdentifier?) {
    guard case .streaming(var context) = self else { return }
    context.pendingTask = taskId
    self = .streaming(context)
  }

  mutating func reset() {
    self = .idle
  }

  // MARK: - Queries

  var isStreaming: Bool {
    if case .streaming = self {
      return true
    }
    return false
  }

  var context: StreamingContext? {
    if case .streaming(let context) = self {
      return context
    }
    return nil
  }
}

// MARK: - STT State

/// Manages STT session state and context.
///
/// Accumulates audio chunks until transcription is requested via audio-stop event.
enum STTState: Equatable {
  case idle
  case collectingAudio(AudioContext)

  struct AudioContext: Equatable {
    var buffer: Data
    var language: String?
    var sampleRate: UInt32
    var channels: UInt32
    var width: UInt32

    init(
      buffer: Data = Data(),
      language: String? = nil,
      sampleRate: UInt32 = 16000,
      channels: UInt32 = 1,
      width: UInt32 = 2
    ) {
      self.buffer = buffer
      self.language = language
      self.sampleRate = sampleRate
      self.channels = channels
      self.width = width
    }
  }

  // MARK: - State Transitions

  mutating func startTranscription(language: String?) {
    self = .collectingAudio(AudioContext(language: language))
  }

  mutating func updateAudioFormat(sampleRate: UInt32, channels: UInt32, width: UInt32) {
    guard case .collectingAudio(var context) = self else { return }
    context.sampleRate = sampleRate
    context.channels = channels
    context.width = width
    self = .collectingAudio(context)
  }

  mutating func appendAudio(_ data: Data) {
    guard case .collectingAudio(var context) = self else { return }
    context.buffer.append(data)
    self = .collectingAudio(context)
  }

  mutating func reset() {
    self = .idle
  }

  // MARK: - Queries

  var isCollecting: Bool {
    if case .collectingAudio = self {
      return true
    }
    return false
  }

  var context: AudioContext? {
    if case .collectingAudio(let context) = self {
      return context
    }
    return nil
  }
}

/// Handles a single Wyoming protocol client connection.
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

  // state machines for TTS and STT services
  private var ttsState = TTSStreamingState.idle
  private var sttState = STTState.idle
  private var activeTasks: [TTSStreamingState.TaskIdentifier: Task<Void, Never>] = [:]

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

  /// Process audio buffer from streaming synthesis callback.
  private func processStreamingAudioBuffer(audioData: Data, audioFormat: AudioFormat) {
    sendAudioChunk(audioData, format: audioFormat)
  }

  /// Quick check if text looks like SSML (for streaming detection).
  ///
  /// Just checks prefix and closing tag, doesn't validate XML structure.
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
        #if DEBUG
          networkLogger.debug("len(buffer)=\(self.receiveBuffer.count)")
        #endif
        self.metricsCollector.recordNetworkTraffic(bytesIn: UInt64(data.count), bytesOut: 0)
        self.processBuffer()
      }

      if isComplete {
        networkLogger.debug("Connection closed by client")
        self.close()
        self.onClose?()
        return
      }

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
    if ttsState.isStreaming {
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
    ttsState.startStreaming(voiceIdentifier: voiceIdentifier)
    wyomingServerLogger.debug("Streaming synthesis started")
  }

  private func handleSynthesizeChunk(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesizeChunk called")

    guard ttsState.isStreaming else {
      wyomingServerLogger.info("Not in streaming synthesis mode")
      return
    }
    guard let synthesizeChunkEvent = parseEvent(message, as: SynthesizeChunkEvent.self) else {
      return
    }

    ttsState.appendText(synthesizeChunkEvent.text)

    let currentBuffer = ttsState.context?.textBuffer ?? ""
    wyomingServerLogger.debug(
      "Added chunk to buffer: '\(synthesizeChunkEvent.text)' (total buffer: \(currentBuffer.count) chars)")

    if let context = ttsState.context, !context.ssmlMode && looksLikeSSML(currentBuffer) {
      ttsState.setSSMLMode(true)
      wyomingServerLogger.info("SSML detected in streaming buffer - will chunk by first-level nodes")
    }

    let taskId = TTSStreamingState.TaskIdentifier(id: UUID())
    let task = Task {
      await processSentencesFromBuffer()
      activeTasks.removeValue(forKey: taskId)
      ttsState.setPendingTask(nil)
    }
    activeTasks[taskId] = task
    ttsState.setPendingTask(taskId)
  }

  private func processSentencesFromBuffer() async {
    guard let context = ttsState.context else { return }

    if context.ssmlMode {
      let trimmed = context.textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
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
            voiceIdentifier: context.voiceIdentifier,
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

      ttsState.updateTextBuffer(remainingText)
      if !remainingText.isEmpty && !looksLikeSSML(remainingText) {
        ttsState.setSSMLMode(false)
        wyomingServerLogger.notice("Remaining text after SSML is plain text, switching to plain text mode")
      } else if !remainingText.isEmpty {
        wyomingServerLogger.debug("Remaining text after SSML looks like SSML, staying in SSML mode")
      }
    } else {
      // process complete sentences from buffer
      while true {
        guard let currentContext = ttsState.context else { break }
        guard let (sentence, remaining) = ttsService.extractCompleteSentence(from: currentContext.textBuffer) else {
          break
        }

        wyomingServerLogger.info("Synthesizing sentence: '\(sentence)'")
        ttsState.updateTextBuffer(remaining)

        do {
          try await ttsService.synthesizeWithCallback(
            text: sentence,
            voiceIdentifier: currentContext.voiceIdentifier,
            onAudioBuffer: { [weak self] audioData, audioFormat in
              self?.processStreamingAudioBuffer(audioData: audioData, audioFormat: audioFormat)
            }
          )

          // add pause between sentences
          if let format = ttsState.context?.audioFormat, settingsManager.defaultTTSPause > 0 {
            let silence = ttsService.generateSilence(
              duration: TimeInterval(settingsManager.defaultTTSPause), format: format)
            sendAudioChunk(silence, format: format)
          }
        } catch {
          wyomingServerLogger.error("Sentence synthesis error: \(error)")
          metricsCollector.recordConnectionError()
          close()
          break
        }
      }
    }
  }

  private func handleSynthesizeStop(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleSynthesizeStop called")

    guard ttsState.isStreaming else {
      wyomingServerLogger.info("Not in streaming synthesis mode")
      return
    }

    guard parseEvent(message, as: SynthesizeStopEvent.self) != nil else {
      return
    }

    Task {
      // wait for any pending processing task to complete
      if let context = ttsState.context, let taskId = context.pendingTask {
        wyomingServerLogger.debug("Waiting for pending processing task to complete")
        await activeTasks[taskId]?.value
        activeTasks.removeValue(forKey: taskId)
        ttsState.setPendingTask(nil)
      }

      wyomingServerLogger.debug("Processing final synthesis buffer")

      var hadError = false
      if let context = ttsState.context, !context.textBuffer.isEmpty {
        if context.ssmlMode {
          wyomingServerLogger.info("Synthesizing complete SSML document: '\(context.textBuffer)'")
        } else {
          wyomingServerLogger.info("Synthesizing remaining text: '\(context.textBuffer)'")
        }
        do {
          try await ttsService.synthesizeWithCallback(
            text: context.textBuffer,
            voiceIdentifier: context.voiceIdentifier,
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

      ttsState.reset()

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
      wyomingServerLogger.info("Specified language: '\(language)'")
    } else {
      wyomingServerLogger.info("No language specified, using default")
    }

    sttStartTime = Date()
    sttState.startTranscription(language: transcribeEvent.language)
  }

  private func handleAudioStart(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioStart called")

    guard let audioStartEvent = parseEvent(message, as: AudioStartEvent.self) else {
      return
    }

    sttState.updateAudioFormat(
      sampleRate: audioStartEvent.format.rate,
      channels: audioStartEvent.format.channels,
      width: audioStartEvent.format.width
    )
    if let context = sttState.context {
      wyomingServerLogger.debug(
        "audio-start: sample rate: \(context.sampleRate) Hz, width: \(context.width), channels: \(context.channels)")
    }
  }

  private func handleAudioChunk(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioChunk called")

    guard sttState.isCollecting else { return }

    guard let audioChunkEvent = parseEvent(message, as: AudioChunkEvent.self) else {
      return
    }

    sttState.appendAudio(audioChunkEvent.audio)

    if let context = sttState.context {
      wyomingServerLogger.debug(
        "audio-chunk: \(audioChunkEvent.audio.count) bytes, total: \(context.buffer.count) bytes")
    }
  }

  private func handleAudioStop(_ message: WyomingMessage) {
    wyomingServerLogger.debug("handleAudioStop called")

    guard sttState.isCollecting else { return }

    if let audioStopEvent = parseEvent(message, as: AudioStopEvent.self),
      let timestamp = audioStopEvent.timestamp
    {
      wyomingServerLogger.debug("audio-stop: timestamp: \(timestamp) ms")
    }

    // capture context before resetting
    guard let context = sttState.context else { return }
    let audioData = context.buffer
    let language = context.language
    let sampleRate = context.sampleRate
    let channels = context.channels

    sttState.reset()

    wyomingServerLogger.debug("Starting transcription with \(audioData.count) bytes of audio")

    Task {
      do {
        sendTranscriptStart(language: language)

        let text = try await sttService.transcribe(
          audioData: audioData,
          sampleRate: sampleRate,
          channels: channels,
          language: language,
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
    if ttsState.isStreaming, let context = ttsState.context, !context.audioStreamStarted {
      let startMessage = AudioStartEvent(format: format, timestamp: nil).toMessage()
      sendMessage(startMessage)
      ttsState.markAudioStreamStarted(format: format)
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
