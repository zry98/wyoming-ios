import Foundation

/// Represents a typed KV pair for LLM additional context.
struct LLMAdditionalContextItem: Codable, Identifiable {
  let id: UUID
  var key: String
  var value: String
  var type: ValueType

  enum ValueType: String, Codable, CaseIterable {
    case string = "String"
    case bool = "Boolean"
    case number = "Number"

    var displayName: String {
      rawValue
    }
  }

  init(id: UUID = UUID(), key: String, value: String, type: ValueType) {
    self.id = id
    self.key = key
    self.value = value
    self.type = type
  }

  func toSendableValue() -> (any Sendable)? {
    switch type {
    case .string:
      return value
    case .bool:
      let lowercased = value.lowercased()
      if lowercased == "true" {
        return true
      } else if lowercased == "false" {
        return false
      }
      return nil
    case .number:
      return Double(value)
    }
  }
}
