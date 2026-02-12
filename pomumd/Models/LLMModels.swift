import Foundation
import MLXLMCommon

// MARK: - Model Definition

/// Represents an available LLM model.
struct LLMModel: Identifiable, Hashable {
  let id: String
  let name: String
  let configuration: ModelConfiguration

  var displayName: String {
    name
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  static func == (m1: LLMModel, m2: LLMModel) -> Bool {
    m1.id == m2.id
  }
}

// MARK: - Tool Call Types

/// Tool call in OpenAI response format.
struct ToolCallInfo: Codable {
  let id: String
  let type: String
  let function: FunctionInfo

  struct FunctionInfo: Codable {
    let name: String
    let arguments: String
  }
}

// MARK: - Chat Message

/// Represents a message in a chat conversation.
struct ChatMessage: Codable {
  let role: String
  let content: String?
  let toolCalls: [ToolCallInfo]?
  let toolCallId: String?

  init(role: String, content: String?, toolCalls: [ToolCallInfo]? = nil, toolCallId: String? = nil) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallId = toolCallId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decode(String.self, forKey: .role)
    toolCalls = try container.decodeIfPresent([ToolCallInfo].self, forKey: .toolCalls)
    toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)

    // try to decode content as string first
    if let stringContent = try? container.decode(String.self, forKey: .content) {
      content = stringContent
    } else if let arrayContent = try? container.decode([ContentPart].self, forKey: .content) {
      // if content is an array, extract text from all text parts
      content = arrayContent.compactMap { part in
        if case .text(let text) = part {
          return text
        }
        return nil
      }.joined(separator: "\n")
    } else {
      // content can be null for assistant tool-call messages
      content = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(content, forKey: .content)
    try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
  }

  enum ContentPart: Codable {
    case text(String)
    case other

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: ContentPartKeys.self)
      let type = try container.decode(String.self, forKey: .type)

      switch type {
      case "text":
        let text = try container.decode(String.self, forKey: .text)
        self = .text(text)
      default:
        // TODO: support other types (.e.g, image)
        self = .other
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: ContentPartKeys.self)
      switch self {
      case .text(let text):
        try container.encode("text", forKey: .type)
        try container.encode(text, forKey: .text)
      case .other:
        break
      }
    }

    enum ContentPartKeys: String, CodingKey {
      case type
      case text
    }
  }
}

// MARK: - Chat Completion Request

/// Request for chat completion.
struct ChatCompletionRequest: Codable {
  let messages: [ChatMessage]
  let model: String?
  let stream: Bool?
  let temperature: Float?
  let maxTokens: Int?
  let topP: Float?
  let additionalContext: [String: AnyCodable]?
  let tools: [[String: AnyCodable]]?

  enum CodingKeys: String, CodingKey {
    case messages
    case model
    case stream
    case temperature
    case maxTokens = "max_tokens"
    case topP = "top_p"
    case additionalContext = "additional_context"
    case tools
  }
}

// MARK: - Chat Completion Chunk (Streaming)

/// Streaming chunk for chat completion.
struct ChatCompletionChunk: Codable {
  let id: String
  let object: String
  let model: String
  let choices: [Choice]

  struct Choice: Codable {
    let index: Int
    let delta: Delta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case index
      case delta
      case finishReason = "finish_reason"
    }
  }

  struct Delta: Codable {
    let role: String?
    let content: String?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(role, forKey: .role)
      try container.encode(content, forKey: .content)
    }

    enum CodingKeys: String, CodingKey {
      case role
      case content
    }
  }
}

// MARK: - Chat Completion Response

/// Response for chat completion.
struct ChatCompletionResponse: Codable {
  let object: String
  let id: String
  let model: String
  let choices: [Choice]
  let usage: Usage

  struct Choice: Codable {
    let index: Int
    let message: ChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case index
      case message
      case finishReason = "finish_reason"
    }
  }

  struct Usage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
    }
  }
}

// MARK: - Service Info

/// Information about the LLM service.
struct LLMServiceInfo: Codable {
  let status: String
  let currentModel: String?
  let isModelLoaded: Bool
  let availableModels: [String]

  enum CodingKeys: String, CodingKey {
    case status
    case currentModel = "current_model"
    case isModelLoaded = "is_model_loaded"
    case availableModels = "available_models"
  }
}

// MARK: - Error Response

/// Error response for API.
struct LLMErrorResponse: Codable {
  let error: ErrorDetail

  struct ErrorDetail: Codable {
    let message: String
    let type: String
    let code: String?
  }
}
