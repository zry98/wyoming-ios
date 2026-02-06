import AVFoundation
import Combine
import Network
import Speech
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var serverManager: ServerManager
  @StateObject private var networkMonitor = NetworkMonitor()
  @State private var showAlert = false
  @State private var alertTitle = ""
  @State private var alertMessage = ""

  #if os(iOS)
    @State private var showBlackScreen = false
    @State private var savedBrightness: CGFloat = 1.0

    private var currentScreen: UIScreen? {
      guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
        return nil
      }
      return windowScene.screen
    }
  #endif

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
            Stepper(value: $serverManager.settingsManager.defaultTTSSynthesisTimeout, in: 5...120, step: 1) {
              HStack {
                Text("Synthesis Timeout")
                Spacer()
                Text(String(format: "%ds", serverManager.settingsManager.defaultTTSSynthesisTimeout))
                  .foregroundColor(.secondary)
              }
            }

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
            if networkMonitor.interfaces.isEmpty {
              HStack {
                Text("IP Address")
                Spacer()
                Text("?")
                  .foregroundColor(.secondary)
              }
            } else {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(networkMonitor.interfaces.enumerated()), id: \.element.id) { idx, interface in
                  HStack {
                    if idx == 0 {
                      Text("IP Address")
                    }
                    Spacer()
                    Text(interface.address)
                      .font(.system(.body, design: .monospaced))
                      .foregroundColor(.secondary)
                      .textSelection(.enabled)
                  }
                }
              }
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
        .navigationTitle("PomumD")
        .inlineNavigationBarTitle()
        .toolbar {
          #if os(iOS)
            ToolbarItem(placement: .trailingBar) {
              Button(action: {
                if let screen = currentScreen {
                  savedBrightness = screen.brightness
                  screen.brightness = 0.0
                  showBlackScreen = true
                }
              }) {
                Image(systemName: "moon.fill")
              }
            }
          #endif
        }
        .alert(alertTitle, isPresented: $showAlert) {
          Button("OK", role: .cancel) {}
        } message: {
          Text(alertMessage)
        }
      }

      #if os(iOS)
        if showBlackScreen {
          Color.black
            .ignoresSafeArea()
            .onTapGesture {
              if let screen = currentScreen {
                screen.brightness = savedBrightness
              }
              showBlackScreen = false
            }
        }
      #endif
    }
    #if os(iOS)
      .statusBar(hidden: showBlackScreen)
    #endif
  }

  private func restartServers() {
    serverManager.restartServers()

    if let error = serverManager.errorMessage {
      alertTitle = "Error"
      alertMessage = error
      showAlert = true
    }
  }

}

#Preview {
  ContentView()
    .environmentObject(ServerManager())
}
