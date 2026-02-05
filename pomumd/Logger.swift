import Foundation
import OSLog
import os

struct Logger {
  private let osLogger: os.Logger

  init(subsystem: String, category: String) {
    self.osLogger = os.Logger(subsystem: subsystem, category: category)
  }

  func debug(_ message: String) {
    osLogger.debug("\(message)")
  }

  func info(_ message: String) {
    osLogger.info("\(message)")
  }

  func notice(_ message: String) {
    osLogger.notice("\(message)")
  }

  func warning(_ message: String) {
    osLogger.warning("\(message)")
  }

  func error(_ message: String) {
    osLogger.error("\(message)")
  }

  func fault(_ message: String) {
    osLogger.fault("\(message)")
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

@available(iOS 15.0, *)
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
