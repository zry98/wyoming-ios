import OSLog
import SwiftUI

extension LogLevel {
  var color: Color {
    switch self {
    case .debug: return .secondary
    case .info: return .primary
    case .notice: return .blue
    case .error: return .red
    case .fault: return .purple
    }
  }
}

/// Real-time log viewer with filtering and search.
struct LogsView: View {
  @StateObject private var logManager = LogManager()
  @State private var filteredLogs: [OSLogEntryLog] = []
  @State private var searchText = ""
  @State private var autoScroll = true
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var minimumLevel: LogLevel = .info

  /// Filters logs on background thread to avoid blocking UI.
  private func updateFilteredLogs() {
    Task.detached(priority: .userInitiated) {
      let filtered = await logManager.logs.filter { entry in
        let logLevel = LogLevel.from(entry.level)
        let meetsLevelRequirement = logLevel.rawValue >= minimumLevel.rawValue
        let meetsSearchRequirement =
          searchText.isEmpty || entry.composedMessage.localizedCaseInsensitiveContains(searchText)
        return meetsLevelRequirement && meetsSearchRequirement
      }

      await MainActor.run {
        filteredLogs = filtered
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let error = errorMessage {
        Text("Error loading logs: \(error)")
          .foregroundColor(.red)
          .padding()
      }

      ScrollViewReader { proxy in
        List {
          ForEach(filteredLogs, id: \.date.timeIntervalSince1970) { entry in
            LogEntryRow(entry: entry)
          }
        }
        .listStyle(.plain)
        .onChange(of: filteredLogs.count) {
          if autoScroll, let lastLog = filteredLogs.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              withAnimation {
                proxy.scrollTo(lastLog.date.timeIntervalSince1970, anchor: .bottom)
              }
            }
          }
        }
      }
    }
    .navigationTitle("Logs")
    .inlineNavigationBarTitle()
    .searchable(text: $searchText, prompt: "Search")
    .onChange(of: searchText) {
      updateFilteredLogs()
    }
    .onChange(of: minimumLevel) {
      updateFilteredLogs()
    }
    .toolbar {
      ToolbarItemGroup(placement: .trailingBar) {
        Menu {
          Picker("Minimum Level", selection: $minimumLevel) {
            ForEach(LogLevel.allCases) { level in
              Text(level.displayName).tag(level)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label("Level: \(minimumLevel.displayName)", systemImage: "line.3.horizontal.decrease.circle")
        }

        Button(action: { autoScroll.toggle() }) {
          Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
        }

        Button(action: {
          logManager.clearLogs()
          logManager.startMonitoring(interval: 5.0)
        }) {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    .onAppear {
      logManager.startMonitoring(interval: 5.0)
      updateFilteredLogs()
    }
    .onDisappear {
      logManager.stopMonitoring()
    }
    .onChange(of: logManager.logs) {
      updateFilteredLogs()
    }
    .onChange(of: searchText) {
      updateFilteredLogs()
    }
    .onChange(of: minimumLevel) {
      updateFilteredLogs()
    }
  }
}

struct LogEntryRow: View {
  let entry: OSLogEntryLog

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()

  private var logLevel: LogLevel {
    LogLevel.from(entry.level)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(Self.timestampFormatter.string(from: entry.date))
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        Text("[\(entry.category)]")
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(logLevel.color)

        Spacer()

        Text(logLevel.displayName.uppercased())
          .font(.system(.caption2, design: .monospaced))
          .foregroundColor(logLevel.color)
      }

      Text(entry.composedMessage)
        .font(.system(.body, design: .monospaced))
        .foregroundColor(logLevel.color)
    }
    .padding(.vertical, 4)
  }
}
