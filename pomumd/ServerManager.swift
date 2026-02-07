import Combine
import Foundation
import Prometheus
import Speech

/// Central orchestrator managing HTTP, Wyoming, and Bonjour services.
@MainActor
class ServerManager: ObservableObject {
  let httpServer: HTTPServer
  let wyomingServer: WyomingServer
  let bonjourService: BonjourService
  static let httpServerPort: UInt16 = 10100  // HTTP API port
  static let wyomingServerPort: UInt16 = 10200  // Wyoming protocol port

  @Published var errorMessage: String?
  @Published var hasRequestedPermissions = false
  @Published var settingsManager: SettingsManager
  let prometheusRegistry: PrometheusCollectorRegistry
  let metricsCollector: MetricsCollector
  private var cancellables = Set<AnyCancellable>()

  init() {
    let settingsManager = SettingsManager()

    let metricsConfig = MetricsService.bootstrap()
    self.prometheusRegistry = metricsConfig.prometheusRegistry
    self.metricsCollector = metricsConfig.metricsCollector

    self.httpServer = HTTPServer(
      port: Self.httpServerPort,
      metricsCollector: metricsCollector,
      registry: prometheusRegistry,
      settingsManager: settingsManager,
    )

    self.wyomingServer = WyomingServer(
      port: Self.wyomingServerPort,
      metricsCollector: metricsCollector,
      settingsManager: settingsManager,
    )

    self.bonjourService = BonjourService(port: Self.wyomingServerPort)

    self.settingsManager = settingsManager

    // Forward changes from nested ObservableObjects to trigger SwiftUI view updates
    wyomingServer.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &cancellables)

    httpServer.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &cancellables)

    bonjourService.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &cancellables)
  }

  // MARK: - Server Lifecycle

  func startServers() {
    let errors = [
      startServer(name: "HTTP", port: Self.httpServerPort) { try httpServer.start() },
      startServer(name: "Wyoming", port: Self.wyomingServerPort) { try wyomingServer.start() },
    ].compactMap { $0 }

    if errors.isEmpty {
      bonjourService.publish()  // publish Zeroconf only after Wyoming server is successfully started
    }

    errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func startServer(name: String, port: UInt16, start: () throws -> Void) -> String? {
    do {
      try start()
      wyomingServerLogger.info("\(name) server started on port \(port)")
      return nil
    } catch {
      let message = "Failed to start \(name) server on port \(port): \(error.localizedDescription)"
      wyomingServerLogger.error("\(message)")
      return message
    }
  }

  func stopServers() {
    bonjourService.unpublish()
    wyomingServer.stop()
    httpServer.stop()
    wyomingServerLogger.notice("Servers stopped")
  }

  func restartServers() {
    stopServers()

    Task { @MainActor in
      metricsCollector.recordServerRestart()
      try? await Task.sleep(for: .seconds(1))
      startServers()
    }
  }

  // MARK: - Permissions

  func requestPermissions(onComplete: @escaping (Bool) -> Void) {
    guard !hasRequestedPermissions else {
      onComplete(true)
      return
    }

    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        self.hasRequestedPermissions = true
        switch status {
        case .authorized:
          appLogger.debug("Speech recognition authorized")
          onComplete(true)
        case .denied:
          self.errorMessage = "Speech recognition denied. Please enable it in Settings."
          appLogger.error("Speech recognition denied")
          onComplete(false)
        case .restricted:
          self.errorMessage = "Speech recognition is restricted on this device."
          appLogger.error("Speech recognition restricted")
          onComplete(false)
        case .notDetermined:
          fallthrough
        @unknown default:
          self.errorMessage = "Unknown speech recognition authorization status."
          appLogger.error("Speech recognition status unknown")
          onComplete(false)
        }
      }
    }
  }
}
