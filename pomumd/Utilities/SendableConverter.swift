import Foundation

/// Utility for converting dynamic types to Sendable types.
///
/// Provides recursive conversion of dictionaries, arrays, and primitive types
/// to Sendable-conforming types for use with concurrent APIs.
enum SendableConverter {

  /// Converts an arbitrary value to a Sendable type.
  ///
  /// Handles nested dictionaries, arrays, and primitive types (Bool, Int, Double, String).
  /// Falls back to String description for unsupported types.
  ///
  /// - Parameter value: The value to convert
  /// - Returns: A Sendable-conforming value
  static func convertToSendable(_ value: Any) -> any Sendable {
    if let dict = value as? [String: Any] {
      return convertDictToSendable(dict)
    } else if let array = value as? [Any] {
      return array.map { convertToSendable($0) }
    } else if let bool = value as? Bool {
      return bool
    } else if let int = value as? Int {
      return int
    } else if let double = value as? Double {
      return double
    } else if let string = value as? String {
      return string
    }
    return String(describing: value)
  }

  /// Converts a dictionary with Any values to a dictionary with Sendable values.
  ///
  /// Recursively processes nested dictionaries and arrays.
  ///
  /// - Parameter dict: Dictionary with Any values
  /// - Returns: Dictionary with Sendable values
  static func convertDictToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
    var result: [String: any Sendable] = [:]
    for (key, value) in dict {
      result[key] = convertToSendable(value)
    }
    return result
  }
}
