import Foundation
import OSLog
import os

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

struct LogEntry: Codable {
  let timestamp: String
  let level: String
  let category: String
  let message: String

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

private let subsystem =
  Bundle.main.infoDictionary?["CFBundleName"] as? String
  ?? Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
  ?? "pomumd"

let ttsLogger = Logger(subsystem: subsystem, category: "tts")

let sttLogger = Logger(subsystem: subsystem, category: "stt")

let networkLogger = Logger(subsystem: subsystem, category: "network")

let httpServerLogger = Logger(subsystem: subsystem, category: "http")

let wyomingServerLogger = Logger(subsystem: subsystem, category: "wyoming")

let metricsLogger = Logger(subsystem: subsystem, category: "metrics")

let appLogger = Logger(subsystem: subsystem, category: "app")

let bonjourLogger = Logger(subsystem: subsystem, category: "bonjour")

enum LogStoreAccess {
  static func retrieveLogs(since: Date? = nil, maxCount: Int = 5000) throws -> [OSLogEntryLog] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let startTime = since ?? Date().addingTimeInterval(-3600)
    let position = store.position(date: startTime)

    var logs: [OSLogEntryLog] = []
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
