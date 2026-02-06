import OSLog
import SwiftUI

// MARK: - UI Extensions for LogLevel

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

struct LogsView: View {
  @State private var logs: [OSLogEntryLog] = []
  @State private var filteredLogs: [OSLogEntryLog] = []
  @State private var logIds: Set<TimeInterval> = []
  @State private var searchText = ""
  @State private var autoScroll = true
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var minimumLevel: LogLevel = .info
  @State private var lastFetchTime: Date?
  @State private var refreshTimer: Timer?

  private func updateFilteredLogs() {
    filteredLogs = logs.filter { entry in
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
          ForEach(filteredLogs, id: \.date.timeIntervalSince1970) { entry in
            LogEntryRow(entry: entry)
          }
        }
        .listStyle(.plain)
        .onChange(of: filteredLogs.count) { _ in
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
    .onChange(of: searchText) { _ in
      updateFilteredLogs()
    }
    .onChange(of: minimumLevel) { _ in
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

        if lastFetchTime == nil {
          logs = retrievedLogs
          logIds = Set(retrievedLogs.map { $0.date.timeIntervalSince1970 })
        } else {
          let newLogs = retrievedLogs.filter { !logIds.contains($0.date.timeIntervalSince1970) }

          if !newLogs.isEmpty {
            logs.append(contentsOf: newLogs)
            logIds.formUnion(newLogs.map { $0.date.timeIntervalSince1970 })

            if logs.count > 10000 {
              let removeCount = logs.count - 10000
              let removedLogs = logs.prefix(removeCount)
              logIds.subtract(removedLogs.map { $0.date.timeIntervalSince1970 })
              logs.removeFirst(removeCount)
            }
          }
        }

        lastFetchTime = fetchTime
        updateFilteredLogs()
        isLoading = false
      } catch {
        errorMessage = error.localizedDescription
        isLoading = false
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
