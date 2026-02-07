import SwiftUI

@main
struct pomumdApp: App {
  @StateObject private var serverManager = ServerManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(serverManager)
        .onAppear {
          startServers()
        }
    }
  }

  /// Requests permissions (e.g., speech recognition) before starting servers.
  private func startServers() {
    serverManager.requestPermissions { authorized in
      if authorized {
        serverManager.startServers()
      }
    }
  }
}
