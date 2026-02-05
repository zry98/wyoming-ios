import Combine
import Foundation
import Prometheus
import Telegraph

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
      httpServerLogger.warning("HTTP server already running")
      return
    }

    server = Server()

    // register routes
    registerHealthRoutes()
    registerMetricsRoutes()
    registerSettingsRoutes()

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

      let sema = DispatchSemaphore(value: 0)
      Task {
        await self.metricsCollector.updateHardwareMetrics()
        sema.signal()
      }
      sema.wait()

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
