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

// MARK: - Chat Message

/// Represents a message in a chat conversation.
struct ChatMessage: Codable {
  let role: String
  let content: String

  init(role: String, content: String) {
    self.role = role
    self.content = content
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    role = try container.decode(String.self, forKey: .role)

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
      throw DecodingError.typeMismatch(
        String.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Content must be either a string or an array of content parts"
        )
      )
    }
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
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
  let temperature: Float?
  let maxTokens: Int?
  let topP: Float?
  let stream: Bool?
  let additionalContext: [String: AnyCodable]?

  enum CodingKeys: String, CodingKey {
    case messages
    case model
    case temperature
    case maxTokens = "max_tokens"
    case topP = "top_p"
    case stream
    case additionalContext = "additional_context"
  }
}

// MARK: - Chat Completion Response

/// Response for chat completion.
struct ChatCompletionResponse: Codable {
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

// MARK: - Streaming Response

/// Streaming chunk for chat completion.
struct ChatCompletionChunk: Codable {
  let object: String
  let id: String
  let model: String
  let choices: [ChunkChoice]

  init(id: String, model: String, choices: [ChunkChoice]) {
    self.object = "chat.completion.chunk"
    self.id = id
    self.model = model
    self.choices = choices
  }

  struct ChunkChoice: Codable {
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
