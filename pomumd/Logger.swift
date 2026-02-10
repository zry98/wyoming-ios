import Combine
import Foundation
import OSLog
import os

/// Wrapper around OSLog for unified logging.
struct Logger {
  private let osLogger: os.Logger

  init(subsystem: String, category: String) {
    self.osLogger = os.Logger(subsystem: subsystem, category: category)
  }

  func debug(_ message: String) {
    osLogger.debug("\(message, privacy: .public)")
  }

  func info(_ message: String) {
    osLogger.info("\(message, privacy: .public)")
  }

  func notice(_ message: String) {
    osLogger.notice("\(message, privacy: .public)")
  }

  func error(_ message: String) {
    osLogger.error("\(message, privacy: .public)")
  }

  func fault(_ message: String) {
    osLogger.fault("\(message, privacy: .public)")
  }
}

/// Log severity levels matching OSLog levels.
/// Used for filtering and displaying logs in the UI.
enum LogLevel: Int, CaseIterable, Identifiable, Codable {
  case debug = 0
  case info = 1
  case notice = 2
  case error = 3
  case fault = 4

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .debug: return "debug"
    case .info: return "info"
    case .notice: return "notice"
    case .error: return "error"
    case .fault: return "fault"
    }
  }

  init?(string: String) {
    switch string.lowercased() {
    case "debug": self = .debug
    case "info": self = .info
    case "notice": self = .notice
    case "error": self = .error
    case "fault": self = .fault
    default: return nil
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

/// Serializable log entry for HTTP API responses.
struct LogEntry: Codable {
  let timestamp: String  // ISO8601 format with fractional seconds
  let level: String  // Log level name (debug, info, notice, error, fault)
  let category: String  // Logger category (tts, stt, network, etc.)
  let message: String  // Composed log message

  private static let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  init(from osLogEntry: OSLogEntryLog) {
    self.timestamp = Self.iso8601Formatter.string(from: osLogEntry.date)
    self.level = LogLevel.from(osLogEntry.level).displayName.lowercased()
    self.category = osLogEntry.category
    self.message = osLogEntry.composedMessage
  }
}

/// App subsystem identifier for OSLog filtering.
private let subsystem =
  Bundle.main.infoDictionary?["CFBundleName"] as? String
  ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
  ?? "pomumd"

/// Category-specific loggers for different app components.
let ttsLogger = Logger(subsystem: subsystem, category: "tts")

let sttLogger = Logger(subsystem: subsystem, category: "stt")

let networkLogger = Logger(subsystem: subsystem, category: "network")

let httpServerLogger = Logger(subsystem: subsystem, category: "http")

let wyomingServerLogger = Logger(subsystem: subsystem, category: "wyoming")

let metricsLogger = Logger(subsystem: subsystem, category: "metrics")

let appLogger = Logger(subsystem: subsystem, category: "app")

let bonjourLogger = Logger(subsystem: subsystem, category: "bonjour")

let llmLogger = Logger(subsystem: subsystem, category: "llm")

/// Utility for retrieving logs from OSLogStore for HTTP API.
enum LogStoreAccess {
  /// Retrieves logs from the current process, filtered by subsystem
  /// Defaults to last hour of logs with a maximum of 5000 entries
  static func retrieveLogs(since: Date? = nil, maxCount: Int = 5000) throws -> [OSLogEntryLog] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let startTime = since ?? Date().addingTimeInterval(-3600)
    let position = store.position(date: startTime)

    var logs: [OSLogEntryLog] = []
    logs.reserveCapacity(maxCount)  // Pre-allocate capacity for better performance
    let entries = try store.getEntries(at: position)

    for entry in entries {
      guard let logEntry = entry as? OSLogEntryLog,
        logEntry.subsystem == subsystem
      else {
        continue
      }

      logs.append(logEntry)

      if logs.count >= maxCount {
        break
      }
    }

    return logs
  }
}

@MainActor
class LogManager: ObservableObject {
  @Published private(set) var logs: [OSLogEntryLog] = []

  private var lastFetchTime: Date?
  private let maxLogCount = 10_000
  private var streamTask: Task<Void, Never>?
  private var consumeTask: Task<Void, Never>?
  private var continuation: AsyncStream<[OSLogEntryLog]>.Continuation?

  // MARK: - Monitoring

  func startMonitoring(interval: TimeInterval = 5.0) {
    stopMonitoring()

    let (stream, continuation) = AsyncStream.makeStream(of: [OSLogEntryLog].self)
    self.continuation = continuation

    streamTask = Task {
      while !Task.isCancelled {
        do {
          let newLogs = try LogStoreAccess.retrieveLogs(
            since: lastFetchTime,
            maxCount: 5000
          )

          if !newLogs.isEmpty {
            continuation.yield(newLogs)
          }

          lastFetchTime = Date()
          try await Task.sleep(for: .seconds(interval))
        } catch {
          continue
        }
      }
      continuation.finish()
    }

    consumeTask = Task {
      for await newLogs in stream {
        appendLogs(newLogs)
      }
    }
  }

  func stopMonitoring() {
    streamTask?.cancel()
    consumeTask?.cancel()
    continuation?.finish()
    streamTask = nil
    consumeTask = nil
    continuation = nil
  }

  // MARK: - Log Management

  /// Appends new logs with deduplication using composite keys.
  private func appendLogs(_ newLogs: [OSLogEntryLog]) {
    let existingKeys = Set(logs.map { logKey($0) })
    let uniqueNewLogs = newLogs.filter { !existingKeys.contains(logKey($0)) }

    logs.append(contentsOf: uniqueNewLogs)

    if logs.count > maxLogCount {
      logs.removeFirst(logs.count - maxLogCount)
    }
  }

  /// Generates composite key (timestamp + message hash) for deduplication.
  private func logKey(_ log: OSLogEntryLog) -> String {
    return "\(log.date.timeIntervalSince1970)_\(log.composedMessage.hashValue)"
  }

  func clearLogs() {
    logs.removeAll()
    lastFetchTime = nil
  }
}
