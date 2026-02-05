import OSLog
import SwiftUI

enum LogLevel: Int, CaseIterable, Identifiable {
  case debug = 0
  case info = 1
  case notice = 2
  case error = 3
  case fault = 4

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .debug: return "Debug"
    case .info: return "Info"
    case .notice: return "Notice"
    case .error: return "Error"
    case .fault: return "Fault"
    }
  }

  var color: Color {
    switch self {
    case .debug: return .secondary
    case .info: return .primary
    case .notice: return .blue
    case .error: return .red
    case .fault: return .purple
    }
  }

  var text: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .notice: return "NOTICE"
    case .error: return "ERROR"
    case .fault: return "FAULT"
    }
  }

  static func from(_ osLogLevel: OSLogEntryLog.Level) -> LogLevel {
    switch osLogLevel {
    case .debug: return .debug
    case .info: return .info
    case .notice: return .notice
    case .error: return .error
    case .fault: return .fault
    default: return .info
    }
  }
}

@available(iOS 15.0, *)
struct LogsView: View {
  @State private var logs: [OSLogEntryLog] = []
  @State private var logIds: Set<TimeInterval> = []
  @State private var searchText = ""
  @State private var autoScroll = true
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var minimumLevel: LogLevel = .info
  @State private var lastFetchTime: Date?
  @State private var refreshTimer: Timer?

  var filteredLogs: [OSLogEntryLog] {
    logs.filter { entry in
      let logLevel = LogLevel.from(entry.level)
      let meetsLevelRequirement = logLevel.rawValue >= minimumLevel.rawValue
      let meetsSearchRequirement =
        searchText.isEmpty || entry.composedMessage.localizedCaseInsensitiveContains(searchText)
      return meetsLevelRequirement && meetsSearchRequirement
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
          ForEach(filteredLogs, id: \.self) { entry in
            LogEntryRow(entry: entry)
          }
        }
        .listStyle(.plain)
        .onChange(of: logs.count) { _ in
          if autoScroll, let lastLog = filteredLogs.last {
            withAnimation {
              proxy.scrollTo(lastLog, anchor: .bottom)
            }
          }
        }
      }
    }
    .navigationTitle("Logs")
    .inlineNavigationBarTitle()
    .searchable(text: $searchText, prompt: "Search")
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

        Button(action: { refreshLogs() }) {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
      }
    }
    .onAppear {
      refreshLogs()
      startAutoRefresh()
    }
    .onDisappear {
      refreshTimer?.invalidate()
      refreshTimer = nil
    }
  }

  private func refreshLogs() {
    isLoading = true
    errorMessage = nil

    Task {
      do {
        let fetchTime = Date()
        let retrievedLogs = try LogStoreAccess.retrieveLogs(since: lastFetchTime)

        await MainActor.run {
          if lastFetchTime == nil {
            logs = retrievedLogs
            logIds = Set(retrievedLogs.map { $0.date.timeIntervalSince1970 })
          } else {
            let newLogs = retrievedLogs.filter { !logIds.contains($0.date.timeIntervalSince1970) }
            logs.append(contentsOf: newLogs)
            newLogs.forEach { logIds.insert($0.date.timeIntervalSince1970) }

            if logs.count > 10000 {
              let removedCount = logs.count - 10000
              let removedLogs = logs.prefix(removedCount)
              removedLogs.forEach { logIds.remove($0.date.timeIntervalSince1970) }
              logs = Array(logs.suffix(10000))
            }
          }

          lastFetchTime = fetchTime
          isLoading = false
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isLoading = false
        }
      }
    }
  }

  private func startAutoRefresh() {
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
      refreshLogs()
    }
  }
}

@available(iOS 15.0, *)
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

        Text(logLevel.text)
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
