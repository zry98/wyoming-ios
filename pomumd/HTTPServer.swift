import Combine
import Foundation
import OSLog
import Prometheus
import Telegraph

// MARK: - Response Models

/// Response structure for logs API endpoint.
struct LogsResponse: Codable {
  let logs: [LogEntry]
  let count: Int
  let since: Double  // Unix timestamp
}

#if !LITE
  /// Helper for decoding dynamic JSON
  struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
      self.value = value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        value = NSNull()
      } else if let bool = try? container.decode(Bool.self) {
        value = bool
      } else if let int = try? container.decode(Int.self) {
        value = int
      } else if let double = try? container.decode(Double.self) {
        value = double
      } else if let string = try? container.decode(String.self) {
        value = string
      } else if let array = try? container.decode([AnyCodable].self) {
        value = array.map { $0.value }
      } else if let dict = try? container.decode([String: AnyCodable].self) {
        value = dict.mapValues { $0.value }
      } else {
        value = ""
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch value {
      case is NSNull:
        try container.encodeNil()
      case let bool as Bool:
        try container.encode(bool)
      case let int as Int:
        try container.encode(int)
      case let double as Double:
        try container.encode(double)
      case let string as String:
        try container.encode(string)
      case let array as [Any]:
        try container.encode(array.map { AnyCodable($0) })
      case let dict as [String: Any]:
        try container.encode(dict.mapValues { AnyCodable($0) })
      default:
        break
      }
    }
  }
#endif

/// HTTP REST API server providing health checks, metrics, settings, and logs.
///
/// Exposes endpoints for:
/// - `/health` - Health check
/// - `/metrics` - Prometheus metrics
/// - `/api/settings` - Get/set settings
/// - `/api/logs` - Retrieve application logs
@MainActor
class HTTPServer: ObservableObject {
  @Published var isRunning: Bool = false
  private var server: Server?
  let port: UInt16

  private let metricsCollector: MetricsCollector
  private let prometheusRegistry: PrometheusCollectorRegistry
  private let settingsManager: SettingsManager
  #if !LITE
    private let llmService: LLMService
  #endif

  private let jsonEncoder = JSONEncoder()
  private let jsonDecoder = JSONDecoder()

  #if !LITE
    init(
      port: UInt16 = 10100,
      metricsCollector: MetricsCollector,
      registry: PrometheusCollectorRegistry,
      settingsManager: SettingsManager,
      llmService: LLMService
    ) {
      self.port = port
      self.metricsCollector = metricsCollector
      self.prometheusRegistry = registry
      self.settingsManager = settingsManager
      self.llmService = llmService
    }
  #else
    init(
      port: UInt16 = 10100,
      metricsCollector: MetricsCollector,
      registry: PrometheusCollectorRegistry,
      settingsManager: SettingsManager
    ) {
      self.port = port
      self.metricsCollector = metricsCollector
      self.prometheusRegistry = registry
      self.settingsManager = settingsManager
    }
  #endif

  func start() throws {
    guard server == nil else {
      httpServerLogger.error("HTTP server already running")
      return
    }

    server = Server()

    registerHealthRoutes()
    registerMetricsRoutes()
    registerSettingsRoutes()
    registerLogRoutes()
    #if !LITE
      registerLLMRoutes()
    #endif

    do {
      try server?.start(port: Int(port))
      isRunning = true
      httpServerLogger.info("HTTP server started on port \(self.port)")
    } catch {
      httpServerLogger.error("Failed to start HTTP server: \(error)")
      throw error
    }
  }

  func stop() {
    server?.stop()
    server = nil
    isRunning = false
    httpServerLogger.notice("HTTP server stopped")
  }

  private func registerHealthRoutes() {
    // GET /health: Health check endpoint
    server?.route(.GET, "/health") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      let resp = HTTPResponse()
      resp.status = .ok
      resp.headers.contentType = "text/plain"
      resp.body = "ok".data(using: .utf8) ?? Data()
      return resp
    }
  }

  private func registerMetricsRoutes() {
    // GET /metrics: Prometheus metrics endpoint
    server?.route(.GET, "/metrics") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      self.metricsCollector.updateHardwareMetrics()

      var buf: [UInt8] = []
      self.prometheusRegistry.emit(into: &buf)
      let metricsOutput = String(decoding: buf, as: UTF8.self)

      let resp = HTTPResponse()
      resp.status = .ok
      resp.headers.contentType = "text/plain; version=0.0.4"
      resp.body = metricsOutput.data(using: .utf8) ?? Data()
      return resp
    }
  }

  private func registerSettingsRoutes() {
    // GET /api/wyoming/settings: Return Wyoming settings
    server?.route(.GET, "/api/wyoming/settings") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      let settings = self.settingsManager.toSettings()
      return self.jsonResponse(settings)
    }

    // POST /api/wyoming/settings: Update Wyoming settings
    server?.route(.POST, "/api/wyoming/settings") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }
      guard !req.body.isEmpty else {
        return self.jsonResponse(error: "Request body is required", status: .badRequest)
      }

      do {
        let settings = try self.jsonDecoder.decode(SettingsManager.Settings.self, from: req.body)
        try self.settingsManager.updateFromSettings(settings)

        return self.jsonResponse([
          "status": "ok",
          "message": "Wyoming settings updated",
        ])
      } catch let error as SettingsError {
        return self.jsonResponse(error: error.localizedDescription, status: .badRequest)
      } catch {
        return self.jsonResponse(error: "Invalid request: \(error.localizedDescription)", status: .badRequest)
      }
    }

    // GET /api/wyoming/tts/voices: Return available TTS voices
    server?.route(.GET, "/api/wyoming/tts/voices") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      let voices = TTSService.getAvailableVoices()
      return self.jsonResponse(voices)
    }

    // GET /api/wyoming/stt/languages: Return available STT languages
    server?.route(.GET, "/api/wyoming/stt/languages") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      let languages = STTService.getLanguages()
      return self.jsonResponse(languages)
    }
  }

  private func registerLogRoutes() {
    // GET /api/logs: Return application logs
    server?.route(.GET, "/api/logs") { [weak self] req in
      guard let self = self else {
        return self?.serverUnavailableResponse() ?? HTTPResponse()
      }

      let queryParams = self.parseQueryParameters(req.uri.queryItems)
      let sinceDate = self.parseSinceParameter(queryParams["since"])
      let maxCount = Int(queryParams["maxCount"] ?? "") ?? 5000
      let minLevel = queryParams["level"].flatMap { LogLevel(string: $0) }
      let categoryFilter = queryParams["category"]

      do {
        var osLogs = try LogStoreAccess.retrieveLogs(since: sinceDate, maxCount: maxCount)

        if let minLevel = minLevel {
          osLogs = osLogs.filter { LogLevel.from($0.level).rawValue >= minLevel.rawValue }
        }
        if let category = categoryFilter, !category.isEmpty {
          osLogs = osLogs.filter { $0.category == category }
        }

        let logEntries = osLogs.map { LogEntry(from: $0) }

        let response = LogsResponse(
          logs: logEntries,
          count: logEntries.count,
          since: sinceDate?.timeIntervalSince1970 ?? 0
        )
        return self.jsonResponse(response)
      } catch {
        httpServerLogger.error("Failed to retrieve logs: \(error.localizedDescription)")
        return self.jsonResponse(
          error: "Failed to retrieve logs: \(error.localizedDescription)", status: .internalServerError)
      }
    }
  }

  #if !LITE
    // MARK: - LLM Routes

    private func registerLLMRoutes() {
      // OpenAI-compatible endpoint: GET /v1/models
      server?.route(.GET, "/v1/models") { [weak self] req in
        guard let self = self else {
          let resp = HTTPResponse()
          resp.status = .internalServerError
          return resp
        }

        let modelNames = self.llmService.getAvailableModelNames()
        let response = ["data": modelNames.map { ["id": $0] }]
        return self.jsonResponse(response)
      }

      // GET /api/llm/settings: Return LLM settings.
      server?.route(.GET, "/api/llm/settings") { [weak self] req in
        guard let self = self else {
          let resp = HTTPResponse()
          resp.status = .internalServerError
          return resp
        }

        struct LLMSettingsResponse: Codable {
          let defaultModel: String
          let defaultTemperature: Float
          let defaultMaxTokens: Int
          let defaultTopP: Float
        }

        let settings = LLMSettingsResponse(
          defaultModel: self.settingsManager.defaultLLMModel,
          defaultTemperature: self.settingsManager.defaultLLMTemperature,
          defaultMaxTokens: self.settingsManager.defaultLLMMaxTokens,
          defaultTopP: self.settingsManager.defaultLLMTopP
        )

        return self.jsonResponse(settings)
      }

      // POST /api/llm/settings: Update LLM settings.
      server?.route(.POST, "/api/llm/settings") { [weak self] req in
        guard let self = self else {
          let resp = HTTPResponse()
          resp.status = .internalServerError
          return resp
        }

        guard !req.body.isEmpty else {
          return self.jsonResponse(error: "Missing request body", status: .badRequest)
        }

        do {
          let settings = try self.jsonDecoder.decode([String: AnyCodable].self, from: req.body)

          if let model = settings["defaultModel"]?.value as? String {
            let availableModels = self.llmService.getAvailableModelNames()
            try self.settingsManager.validateLLMModel(model, availableModels: availableModels)
            self.settingsManager.defaultLLMModel = model
          }

          if let temp = settings["defaultTemperature"]?.value as? Double {
            self.settingsManager.defaultLLMTemperature = Float(temp)
          }

          if let maxTokens = settings["defaultMaxTokens"]?.value as? Int {
            self.settingsManager.defaultLLMMaxTokens = maxTokens
          }

          if let topP = settings["defaultTopP"]?.value as? Double {
            self.settingsManager.defaultLLMTopP = Float(topP)
          }

          return self.jsonResponse(["status": "ok"])
        } catch {
          return self.jsonResponse(error: error.localizedDescription, status: .badRequest)
        }
      }

      // OpenAI-compatible endpoint: POST /v1/chat/completions
      server?.route(.POST, "/v1/chat/completions") { [weak self] req in
        guard let self = self else {
          let resp = HTTPResponse()
          resp.status = .internalServerError
          return resp
        }

        guard !req.body.isEmpty else {
          return self.jsonResponse(error: "Missing request body", status: .badRequest)
        }

        if let bodyString = String(data: req.body, encoding: .utf8) {
          httpServerLogger.debug("Request body: \(bodyString)")
        }

        do {
          let request = try self.jsonDecoder.decode(ChatCompletionRequest.self, from: req.body)
          httpServerLogger.info(
            "POST /v1/chat/completions: model=\(request.model ?? "default"), messages=\(request.messages.count), stream=\(request.stream ?? false)"
          )
          return self.handleChatCompletion(request: request)
        } catch {
          httpServerLogger.error("Failed to parse chat completion request: \(error.localizedDescription)")
          if let decodingError = error as? DecodingError {
            httpServerLogger.error("Decoding error details: \(decodingError)")
          }
          return self.jsonResponse(error: "Invalid request format: \(error.localizedDescription)", status: .badRequest)
        }
      }
    }

    // MARK: - Chat Completion Handlers

    private func handleChatCompletion(request: ChatCompletionRequest) -> HTTPResponse {
      let semaphore = DispatchSemaphore(value: 0)
      var result: HTTPResponse?

      Task { @MainActor in
        do {
          let modelName = request.model ?? self.settingsManager.defaultLLMModel
          let startLoad = Date()
          _ = try await self.llmService.loadModel(modelName)
          let loadDuration = Date().timeIntervalSince(startLoad)
          if loadDuration > 0.1 {
            self.metricsCollector.recordLLMModelLoad(duration: loadDuration)
          }

          self.metricsCollector.recordLLMRequest()

          // Record prompt tokens (approximate word count from all messages)
          let promptTokens = request.messages.reduce(0) { count, message in
            count + (message.content?.split(separator: " ").count ?? 0)
          }
          self.metricsCollector.recordLLMPromptTokens(promptTokens)

          var additionalContext: [String: any Sendable] = [:]
          for item in self.settingsManager.defaultLLMAdditionalContext {
            if let value = item.toSendableValue() {
              additionalContext[item.key] = value
            }
          }
          if let requestContext = request.additionalContext {
            for (key, value) in requestContext {
              additionalContext[key] = value.value
            }
          }

          let toolSpecs = self.convertToToolSpecs(request.tools)

          let startTime = Date()
          let (text, toolCalls) = try await self.llmService.generateSync(
            messages: request.messages,
            temperature: request.temperature ?? self.settingsManager.defaultLLMTemperature,
            maxTokens: request.maxTokens ?? self.settingsManager.defaultLLMMaxTokens,
            topP: request.topP ?? self.settingsManager.defaultLLMTopP,
            additionalContext: additionalContext.isEmpty ? nil : additionalContext,
            tools: toolSpecs
          )
          let duration = Date().timeIntervalSince(startTime)

          self.metricsCollector.recordLLMGeneration(duration: duration)
          self.metricsCollector.recordLLMTokensGenerated(text.split(separator: " ").count)
          self.metricsCollector.recordLLMRequestComplete()

          let hasToolCalls = !toolCalls.isEmpty
          let useStreaming = request.stream == true

          if useStreaming {
            self.metricsCollector.recordLLMStreamingRequest()
            result = self.buildStreamingResponse(
              text: text, toolCalls: toolCalls, modelName: modelName)
          } else {
            let message = ChatMessage(
              role: "assistant",
              content: hasToolCalls ? "" : text,
              toolCalls: hasToolCalls ? toolCalls : nil
            )

            let response = ChatCompletionResponse(
              object: "chat.completion",
              id: UUID().uuidString,
              model: modelName,
              choices: [
                ChatCompletionResponse.Choice(
                  index: 0,
                  message: message,
                  finishReason: hasToolCalls ? "tool_calls" : "stop"
                )
              ],
              usage: ChatCompletionResponse.Usage(
                promptTokens: 0,
                completionTokens: text.split(separator: " ").count,
                totalTokens: text.split(separator: " ").count
              )
            )

            result = self.jsonResponse(response)
          }
        } catch {
          self.metricsCollector.recordLLMError()
          result = self.jsonResponse(error: error.localizedDescription, status: .internalServerError)
        }
        semaphore.signal()
      }

      semaphore.wait()
      return result ?? self.jsonResponse(error: "Unknown error", status: .internalServerError)
    }

    // MARK: - Streaming Response Builder

    private func buildStreamingResponse(
      text: String, toolCalls: [ToolCallInfo], modelName: String
    ) -> HTTPResponse {
      let chunkId = UUID().uuidString
      let hasToolCalls = !toolCalls.isEmpty
      var sseBody = ""

      func appendChunk(role: String?, content: String?, finishReason: String? = nil) {
        let chunk = ChatCompletionChunk(
          id: chunkId,
          object: "chat.completion.chunk",
          model: modelName,
          choices: [
            ChatCompletionChunk.Choice(
              index: 0,
              delta: ChatCompletionChunk.Delta(
                role: role,
                content: content
              ),
              finishReason: finishReason
            )
          ]
        )
        if let data = try? jsonEncoder.encode(chunk),
          let json = String(data: data, encoding: .utf8)
        {
          sseBody += "data: \(json)\n\n"
        }
      }

      if hasToolCalls {
        // Send tool calls via delta.tool_calls where function is a JSON string.
        // home-llm's _extract_response does: [call["function"] for call in tool_calls]
        // Then _async_stream_parse_completion checks isinstance(raw_tool_call, str)
        // and passes it to parse_raw_tool_call which JSON-parses it.
        var toolCallDicts: [[String: Any]] = []
        for tc in toolCalls {
          let toolCallJSON: [String: Any] = [
            "name": tc.function.name,
            "arguments": tc.function.arguments,
          ]
          if let data = try? JSONSerialization.data(withJSONObject: toolCallJSON, options: [.sortedKeys]),
            let jsonStr = String(data: data, encoding: .utf8)
          {
            toolCallDicts.append(["function": jsonStr])
          }
        }

        // Build the chunk manually since we need function as a string, not an object
        let chunkDict: [String: Any] = [
          "id": chunkId,
          "object": "chat.completion.chunk",
          "model": modelName,
          "choices": [
            [
              "index": 0,
              "delta": [
                "role": "assistant",
                "content": "",
                "tool_calls": toolCallDicts,
              ] as [String: Any],
              "finish_reason": NSNull(),
            ] as [String: Any]
          ],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: chunkDict, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8)
        {
          sseBody += "data: \(json)\n\n"
        }
      } else {
        appendChunk(role: "assistant", content: text, finishReason: nil)
      }

      // Final chunk with finish_reason
      appendChunk(role: nil, content: nil, finishReason: "stop")
      sseBody += "data: [DONE]\n\n"

      let resp = HTTPResponse()
      resp.status = .ok
      resp.headers.contentType = "text/event-stream"
      resp.body = sseBody.data(using: .utf8) ?? Data()
      return resp
    }

    // MARK: - Tool Spec Conversion

    private func convertToToolSpecs(_ tools: [[String: AnyCodable]]?) -> [[String: any Sendable]]? {
      guard let tools = tools, !tools.isEmpty else { return nil }
      return tools.map { tool in
        var result: [String: any Sendable] = [:]
        for (key, codable) in tool {
          result[key] = SendableConverter.convertToSendable(codable.value)
        }
        return result
      }
    }
  #endif

  // MARK: - Helper Methods

  private static let iso8601Formatter = ISO8601DateFormatter()

  private static let relativeTimeRegex: NSRegularExpression? = {
    try? NSRegularExpression(pattern: "^(\\d+)([smhd])$", options: [])
  }()

  private func parseQueryParameters(_ queryItems: [URLQueryItem]?) -> [String: String] {
    queryItems?.reduce(into: [:]) { params, item in
      if let value = item.value {
        params[item.name] = value
      }
    } ?? [:]
  }

  private func parseSinceParameter(_ since: String?) -> Date? {
    guard let since = since, !since.isEmpty else {
      return nil
    }

    if let date = Self.iso8601Formatter.date(from: since) {
      return date
    }
    if let timestamp = Double(since) {
      return Date(timeIntervalSince1970: timestamp)
    }
    if let timeInterval = parseRelativeTime(since) {
      return Date().addingTimeInterval(-timeInterval)
    }

    return nil
  }

  private func parseRelativeTime(_ timeString: String) -> TimeInterval? {
    guard let regex = Self.relativeTimeRegex,
      let match = regex.firstMatch(
        in: timeString, options: [], range: NSRange(timeString.startIndex..., in: timeString))
    else {
      return nil
    }

    guard let valueRange = Range(match.range(at: 1), in: timeString),
      let unitRange = Range(match.range(at: 2), in: timeString),
      let value = Double(timeString[valueRange])
    else {
      return nil
    }

    let unit = String(timeString[unitRange])
    switch unit {
    case "s": return value
    case "m": return value * 60
    case "h": return value * 3600
    case "d": return value * 86400
    default: return nil
    }
  }

  private func jsonResponse<T: Encodable>(_ data: T, status: HTTPStatus = .ok) -> HTTPResponse {
    let resp = HTTPResponse()
    resp.status = status

    do {
      let jsonData = try jsonEncoder.encode(data)
      resp.headers.contentType = "application/json"
      resp.body = jsonData
    } catch {
      resp.status = .internalServerError
      resp.body = "{\"error\": \"Failed to encode response\"}".data(using: .utf8) ?? Data()
    }

    return resp
  }

  private func jsonResponse(error: String, status: HTTPStatus) -> HTTPResponse {
    return jsonResponse(["error": error], status: status)
  }

  private func serverUnavailableResponse() -> HTTPResponse {
    return jsonResponse(error: "Server unavailable", status: .internalServerError)
  }
}
