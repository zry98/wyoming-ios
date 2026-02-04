import AVFoundation
import Speech
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var serverManager: ServerManager
  @State private var showAlert = false
  @State private var alertTitle = ""
  @State private var alertMessage = ""
  @State private var showBlackScreen = false

  private var settingsManager: SettingsManager {
    serverManager.settingsManager
  }

  var body: some View {
    ZStack {
      NavigationView {
        List {
          Section("Wyoming Server") {
            HStack {
              Text("Status")
              Spacer()
              Text(serverManager.wyomingServer.isRunning ? "Running" : "Stopped")
                .foregroundColor(serverManager.wyomingServer.isRunning ? .green : .red)
            }

            HStack {
              Text("Port")
              Spacer()
              Text("\(String(serverManager.wyomingServer.port))")
                .foregroundColor(.secondary)
            }
          }

          Section("Text-to-Speech Settings") {
            NavigationLink(
              destination: TTSVoicesListView(settingsManager: settingsManager)
            ) {
              Text("Voices")
            }
          }

          Section("Speech-to-Text Settings") {
            NavigationLink(
              destination: STTLanguagesListView(settingsManager: settingsManager)
            ) {
              Text("Languages")
            }
          }

          Section("HTTP Server") {
            HStack {
              Text("Status")
              Spacer()
              Text(serverManager.httpServer.isRunning ? "Running" : "Stopped")
                .foregroundColor(serverManager.httpServer.isRunning ? .green : .red)
            }

            HStack {
              Text("Port")
              Spacer()
              Text("\(String(serverManager.httpServer.port))")
                .foregroundColor(.secondary)
            }
          }

          Section {

            HStack {
              Text("IP Address")
              Spacer()
              Text(getIPAddress() ?? "?")
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }

            NavigationLink(destination: LogsView()) {
              Text("View Logs")
            }

            Button(action: restartServers) {
              HStack {
                Spacer()
                Text("Restart Servers")
                  .fontWeight(.semibold)
                  .foregroundColor(.red)
                Spacer()
              }
            }
          }
        }
        .toolbar {
          ToolbarItem(placement: .navigation) {
            Button(action: { showBlackScreen = true }) {
              Image(systemName: "moon.fill")
            }
          }
        }
        .navigationTitle("PomumD")
        .alert(alertTitle, isPresented: $showAlert) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(alertMessage)
        }
      }

      if showBlackScreen {
        Color.black
          .ignoresSafeArea()
          .onTapGesture {
            showBlackScreen = false
          }
      }
    }
  }

  private func restartServers() {
    serverManager.restartServers()

    if let error = serverManager.errorMessage {
      alertTitle = "Error"
      alertMessage = error
      showAlert = true
    }
  }

  private func getIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    if getifaddrs(&ifaddr) == 0 {
      var ptr = ifaddr
      while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }

        guard let interface = ptr?.pointee else { continue }
        let addrFamily = interface.ifa_addr.pointee.sa_family

        if addrFamily == UInt8(AF_INET) {
          let name = String(cString: interface.ifa_name)
          if name == "en0" || name == "en1" {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
              interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
              &hostname, socklen_t(hostname.count),
              nil, socklen_t(0), NI_NUMERICHOST)
            address = String(cString: hostname)
          }
        }
      }
      freeifaddrs(ifaddr)
    }

    return address
  }

}

#Preview {
  ContentView()
    .environmentObject(ServerManager())
}
