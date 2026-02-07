import Combine
import Foundation
import Network

/// Represents a network interface with its IP address
struct NetworkInterface: Identifiable {
  let id = UUID()
  let name: String  // Interface name (e.g., "en0", "utun0")
  let address: String  // IP address (IPv4 or IPv6)
  let isIPv6: Bool
}

/// Monitors network interfaces and publishes available IP addresses.
class NetworkMonitor: ObservableObject {
  @Published var interfaces: [NetworkInterface] = []

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "NetworkMonitor")

  init() {
    startMonitoring()
  }

  deinit {
    stopMonitoring()
  }

  private func startMonitoring() {
    monitor.pathUpdateHandler = { [weak self] _ in
      self?.updateInterfaces()
    }
    monitor.start(queue: queue)

    updateInterfaces()
  }

  private func stopMonitoring() {
    monitor.cancel()
  }

  private func updateInterfaces() {
    let newInterfaces = getNetworkInterfaces()
    DispatchQueue.main.async { [weak self] in
      self?.interfaces = newInterfaces
    }
  }

  private func getNetworkInterfaces() -> [NetworkInterface] {
    var interfaces: [NetworkInterface] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0 else {
      return interfaces
    }

    var ptr = ifaddr
    while ptr != nil {
      defer { ptr = ptr?.pointee.ifa_next }

      guard let interface = ptr?.pointee else { continue }
      let addrFamily = interface.ifa_addr.pointee.sa_family
      let name = String(cString: interface.ifa_name)

      // only physical network (en*) and VPN interfaces (utun*)
      // skip loopback (lo*), AWDL (awdl*), bridge, etc
      guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }

      if addrFamily == UInt8(AF_INET) {
        // IPv4
        let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let ipAddr = addr.sin_addr

        // skip link-local (169.254.0.0/16)
        let firstOctet = (ipAddr.s_addr & 0xFF)
        let secondOctet = ((ipAddr.s_addr >> 8) & 0xFF)
        if firstOctet == 169 && secondOctet == 254 {
          continue
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
          interface.ifa_addr,
          socklen_t(interface.ifa_addr.pointee.sa_len),
          &hostname,
          socklen_t(hostname.count),
          nil,
          socklen_t(0),
          NI_NUMERICHOST
        )

        if result == 0 {
          let address = String(cString: hostname)
          interfaces.append(
            NetworkInterface(
              name: name,
              address: address,
              isIPv6: false
            ))
        }
      } else if addrFamily == UInt8(AF_INET6) {
        // IPv6
        let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }

        // skip link-local (fe80::/10)
        let firstByte = addr.sin6_addr.__u6_addr.__u6_addr8.0
        let secondByte = addr.sin6_addr.__u6_addr.__u6_addr8.1
        if firstByte == 0xFE && (secondByte & 0xC0) == 0x80 {
          continue
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
          interface.ifa_addr,
          socklen_t(interface.ifa_addr.pointee.sa_len),
          &hostname,
          socklen_t(hostname.count),
          nil,
          socklen_t(0),
          NI_NUMERICHOST
        )

        if result == 0 {
          let address = String(cString: hostname)
          // drop scope ID suffix (e.g., %en0)
          let cleanAddress = address.components(separatedBy: "%").first ?? address
          interfaces.append(
            NetworkInterface(
              name: name,
              address: cleanAddress,
              isIPv6: true
            ))
        }
      }
    }

    freeifaddrs(ifaddr)

    // sort interfaces: IPv4 first, then by interface name
    return interfaces.sorted { if1, if2 in
      if if1.isIPv6 != if2.isIPv6 {
        return !if1.isIPv6
      }
      return if1.name < if2.name
    }
  }
}
