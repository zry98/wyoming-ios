import Combine
import Foundation
import Network

/// Manages Bonjour (mDNS Zeroconf) service for Home Assistant discovery.
///
/// Implements the Wyoming protocol service discovery using `_wyoming._tcp.local.`
class BonjourService: NSObject, ObservableObject {
  @Published var isPublished: Bool = false

  private let port: UInt16
  private let serviceName: String
  private var netService: NetService?

  /// Initialize the Bonjour service
  /// - Parameters:
  ///   - port: The port number where the Wyoming server is listening
  ///   - name: Optional custom service name
  init(port: UInt16, name: String? = nil) {
    self.port = port
    self.serviceName = name ?? Self.getServiceName()
    super.init()
  }

  func publish() {
    guard netService == nil else {
      bonjourLogger.error("Bonjour service already published")
      return
    }

    let service = NetService(domain: "local.", type: "_wyoming._tcp.", name: serviceName, port: Int32(port))
    service.delegate = self

    service.publish()

    netService = service
    bonjourLogger.info("Publishing Bonjour service: \(serviceName)._wyoming._tcp.local. on port \(port)")
  }

  func unpublish() {
    guard let service = netService else { return }

    service.stop()
    netService = nil
    isPublished = false
    bonjourLogger.info("Bonjour service unpublished")
  }

  private static func getServiceName() -> String {
    let programName =
      (Bundle.main.infoDictionary?["CFBundleName"] as? String
      ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
      ?? "PomumD")
      .replacingOccurrences(of: " ", with: "-")

    let fullHostName = ProcessInfo.processInfo.hostName
    let hostName = fullHostName.components(separatedBy: ".").first ?? fullHostName

    return "\(programName)-\(hostName)"
  }
}

extension BonjourService: NetServiceDelegate {
  func netServiceDidPublish(_ sender: NetService) {
    DispatchQueue.main.async {
      self.isPublished = true
      bonjourLogger.info("Bonjour service published successfully: \(sender.name)._wyoming._tcp.local.")
    }
  }

  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    DispatchQueue.main.async {
      self.isPublished = false
      let errorCode = errorDict[NetService.errorCode] ?? -1
      let errorDomain = errorDict[NetService.errorDomain] ?? -1
      bonjourLogger.error("Failed to publish Bonjour service: code=\(errorCode), domain=\(errorDomain)")
    }
  }

  func netServiceDidStop(_ sender: NetService) {
    DispatchQueue.main.async {
      self.isPublished = false
      bonjourLogger.debug("Bonjour service stopped")
    }
  }
}
