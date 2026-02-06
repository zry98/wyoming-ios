import Combine
import Foundation
import OSLog
import Prometheus
import Telegraph

// MARK: - Response Models

struct LogsResponse: Codable {
  let logs: [LogEntry]
  let count: Int
  let since: Double
}

@MainActor
class HTTPServer: ObservableObject {
  @Published var isRunning: Bool = false
  private var server: Server?
  let port: UInt16

  private let metricsCollector: MetricsCollector
  private let prometheusRegistry: PrometheusCollectorRegistry
  private let settingsManager: SettingsManager

  private let jsonEncoder = JSONEncoder()
  private let jsonDecoder = JSONDecoder()

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

  func start() throws {
    guard server == nil else {
      httpServerLogger.error("HTTP server already running")
      return
    }

    server = Server()

    // register routes
    registerHealthRoutes()
    registerMetricsRoutes()
    registerSettingsRoutes()
    registerLogRoutes()

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
