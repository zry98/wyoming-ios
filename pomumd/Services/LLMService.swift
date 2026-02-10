import Combine
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

/// Core LLM service for on-device inference using MLX.
@MainActor
class LLMService: ObservableObject {

  // MARK: - Published Properties

  @Published var isModelLoaded: Bool = false
  @Published var currentModelName: String?
  @Published var isDownloading: Bool = false
  @Published var downloadProgress: Double = 0.0
  @Published var errorMessage: String?

  // MARK: - Private Properties

  private var modelContainer: ModelContainer?
  private let modelCache = NSCache<NSString, ModelContainer>()
  private var cancellables = Set<AnyCancellable>()
  private var ongoingDownloads: [String: Task<ModelContainer, Error>] = [:]

  // MARK: - Model Management

  private func getModelConfiguration(_ modelID: String) -> ModelConfiguration? {
    LLMRegistry.shared.configuration(id: modelID)
  }

  // MARK: - Initialization

  init() {
    // increase GPU memory limit to prevent OOM issues
    Memory.cacheLimit = 2 * 1024 * 1024 * 1024  // 2GB

    modelCache.countLimit = 1  // keep max 1 model in memory
  }

  // MARK: - Public Methods

  func getAvailableModelNames() -> [String] {
    return Array(LLMRegistry.shared.models.map { $0.name })
  }

  func isModelDownloaded(_ modelName: String) -> Bool {
    guard let configuration = getModelConfiguration(modelName) else {
      llmLogger.debug("Cannot check download status for '\(modelName)': model not found in registry")
      return false
    }

    let repo = Hub.Repo(id: configuration.name)
    let localPath = HubApi.default.localRepoLocation(repo)

    return FileManager.default.fileExists(atPath: localPath.path)
  }

  func deleteModel(_ modelName: String) async throws {
    guard let configuration = getModelConfiguration(modelName) else {
      llmLogger.error("Cannot delete '\(modelName)': model not found in registry")
      throw LLMError.modelNotFound(modelName)
    }

    let repo = Hub.Repo(id: configuration.name)
    let localPath = HubApi.default.localRepoLocation(repo)

    guard FileManager.default.fileExists(atPath: localPath.path) else {
      llmLogger.notice("Model '\(modelName)' is not downloaded, nothing to delete")
      return
    }
    llmLogger.info("Deleting model: \(modelName)")

    // delete from cache
    modelCache.removeObject(forKey: modelName as NSString)

    // remove from current
    if currentModelName == modelName {
      modelContainer = nil
      currentModelName = nil
      isModelLoaded = false
    }

    // delete files
    do {
      try FileManager.default.removeItem(at: localPath)
      llmLogger.notice("Model '\(modelName)' deleted successfully")
    } catch {
      llmLogger.error("Failed to delete model '\(modelName)': \(error.localizedDescription)")
      throw error
    }
  }

  /// Preload a model on app startup for faster first request
  func preloadModel(_ modelName: String) async {
    guard !modelName.isEmpty else {
      llmLogger.debug("No model specified for preloading, skipping")
      return
    }

    llmLogger.info("Preloading model '\(modelName)' on startup")
    do {
      _ = try await loadModel(modelName)
      llmLogger.notice("Model '\(modelName)' preloaded successfully")
    } catch {
      llmLogger.error("Failed to preload model '\(modelName)': \(error.localizedDescription)")
      // Don't throw - preloading is optional and shouldn't block startup
    }
  }

  /// Unload the currently loaded model to free memory
  func unloadModel() {
    guard let currentModel = currentModelName else {
      llmLogger.debug("No model currently loaded, nothing to unload")
      return
    }

    llmLogger.info("Unloading model: \(currentModel)")
    modelContainer = nil
    currentModelName = nil
    isModelLoaded = false
    llmLogger.notice("Model '\(currentModel)' unloaded successfully")
  }

  func getServiceInfo() -> LLMServiceInfo {
    return LLMServiceInfo(
      status: isModelLoaded ? "ready" : "not_loaded",
      currentModel: currentModelName,
      isModelLoaded: isModelLoaded,
      availableModels: LLMRegistry.shared.models.map { $0.name }
    )
  }

  func cancelDownload(_ modelName: String) {
    llmLogger.info("Cancelling download for model: \(modelName)")

    if let task = ongoingDownloads[modelName] {
      task.cancel()
      ongoingDownloads.removeValue(forKey: modelName)
      llmLogger.notice("Download task for '\(modelName)' cancelled")
    }

    isDownloading = false
    downloadProgress = 0.0
  }

  func loadModel(_ modelName: String) async throws -> ModelContainer {
    llmLogger.info("Loading model: \(modelName)")

    if let cached = modelCache.object(forKey: modelName as NSString) {
      llmLogger.info("Model '\(modelName)' found in cache, using cached version")
      self.modelContainer = cached
      self.currentModelName = modelName
      self.isModelLoaded = true
      return cached
    }

    if let ongoingTask = ongoingDownloads[modelName] {
      llmLogger.info("Model '\(modelName)' download already in progress, waiting for completion")
      do {
        let container = try await ongoingTask.value
        self.modelContainer = container
        self.currentModelName = modelName
        self.isModelLoaded = true
        return container
      } catch {
        llmLogger.error("Ongoing download for '\(modelName)' failed: \(error.localizedDescription)")
        throw error
      }
    }

    guard let configuration = getModelConfiguration(modelName) else {
      llmLogger.error("Model '\(modelName)' not found in registry")
      throw LLMError.modelNotFound(modelName)
    }
    llmLogger.info("Model configuration loaded for '\(modelName)': \(configuration.name)")

    let downloadTask = Task<ModelContainer, Error> {
      await MainActor.run {
        self.isDownloading = true
        self.downloadProgress = 0.0
        self.errorMessage = nil
      }

      llmLogger.info("Starting model download/load for '\(modelName)'")

      do {
        let container = try await LLMModelFactory.shared.loadContainer(
          hub: .default, configuration: configuration
        ) { progress in
          Task { @MainActor in
            self.downloadProgress = progress.fractionCompleted
            if progress.fractionCompleted > 0 && progress.fractionCompleted < 1.0 {
              llmLogger.debug("Model '\(modelName)' download progress: \(Int(progress.fractionCompleted * 100))%")
            }
          }
        }

        await MainActor.run {
          self.modelCache.setObject(container, forKey: modelName as NSString)
          self.modelContainer = container
          self.currentModelName = modelName
          self.isModelLoaded = true
          self.isDownloading = false
        }

        llmLogger.notice("Model '\(modelName)' loaded successfully and cached")

        return container
      } catch {
        await MainActor.run {
          self.isDownloading = false
          self.errorMessage = error.localizedDescription
        }
        llmLogger.error("Failed to load model '\(modelName)': \(error.localizedDescription)")
        throw error
      }
    }

    ongoingDownloads[modelName] = downloadTask

    do {
      let container = try await downloadTask.value
      ongoingDownloads.removeValue(forKey: modelName)
      return container
    } catch {
      ongoingDownloads.removeValue(forKey: modelName)
      throw error
    }
  }

  func generateSync(
    messages: [ChatMessage],
    temperature: Float? = nil,
    maxTokens: Int? = nil,
    topP: Float? = nil,
    repetitionPenalty: Float? = nil,
    additionalContext: [String: any Sendable]? = nil
  ) async throws -> String {
    guard let container = modelContainer else {
      llmLogger.error("Generation failed: no model loaded")
      throw LLMError.modelNotLoaded
    }
    llmLogger.info("Starting synchronous generation with \(messages.count) messages")

    let chat = messages.map { message in
      let role: Chat.Message.Role =
        switch message.role {
        case "assistant":
          .assistant
        case "user":
          .user
        case "system":
          .system
        default:
          .user
        }
      return Chat.Message(role: role, content: message.content)
    }

    let userInput = UserInput(chat: chat, additionalContext: additionalContext)
    let parameters = GenerateParameters(
      maxTokens: maxTokens,
      temperature: temperature ?? 0.7,
      topP: topP ?? 1.0,
      repetitionPenalty: repetitionPenalty
    )

    llmLogger.debug(
      "Generation parameters - temp: \(parameters.temperature), maxTokens: \(parameters.maxTokens ?? -1), topP: \(parameters.topP)"
    )
    if let context = additionalContext, !context.isEmpty {
      llmLogger.debug("Additional context: \(context)")
    }

    do {
      let startTime = Date()

      let stream = try await container.perform { (context: ModelContext) in
        let lmInput = try await context.processor.prepare(input: userInput)
        return try MLXLMCommon.generate(
          input: lmInput, parameters: parameters, context: context)
      }

      var response = ""
      for try await generation in stream {
        switch generation {
        case .chunk(let chunk):
          response += chunk
        case .info, .toolCall:
          break
        }
      }

      let duration = Date().timeIntervalSince(startTime)
      let responseTokens = response.split(separator: " ").count
      let tokensPerSecond = duration > 0 ? Double(responseTokens) / duration : 0

      llmLogger.info("Generation completed successfully")
      llmLogger.info(
        "Statistics: duration=\(String(format: "%.2f", duration))s, tokens=\(responseTokens), tokens/sec=\(String(format: "%.2f", tokensPerSecond)), response_length=\(response.count) chars"
      )
      llmLogger.debug("Generated response: \(response)")
      return response
    } catch {
      llmLogger.error("Generation failed: \(error.localizedDescription)")
      throw error
    }
  }

  func generate(
    messages: [ChatMessage],
    temperature: Float? = nil,
    maxTokens: Int? = nil,
    topP: Float? = nil,
    repetitionPenalty: Float? = nil,
    additionalContext: [String: any Sendable]? = nil
  ) async throws -> AsyncStream<String> {
    guard let container = modelContainer else {
      llmLogger.error("Streaming generation failed: no model loaded")
      throw LLMError.modelNotLoaded
    }
    llmLogger.info("Starting streaming generation with \(messages.count) messages")

    let chat = messages.map { message in
      let role: Chat.Message.Role =
        switch message.role {
        case "assistant":
          .assistant
        case "user":
          .user
        case "system":
          .system
        default:
          .user
        }
      return Chat.Message(role: role, content: message.content)
    }

    let userInput = UserInput(chat: chat, additionalContext: additionalContext)
    let parameters = GenerateParameters(
      maxTokens: maxTokens,
      temperature: temperature ?? 0.7,
      topP: topP ?? 1.0,
      repetitionPenalty: repetitionPenalty
    )

    llmLogger.debug(
      "Generation parameters - temp: \(parameters.temperature), maxTokens: \(parameters.maxTokens ?? -1), topP: \(parameters.topP)"
    )
    if let context = additionalContext, !context.isEmpty {
      llmLogger.debug("Additional context: \(context)")
    }

    return AsyncStream { continuation in
      Task {
        var tokenCount = 0
        var fullResponse = ""
        var firstTokenTime: Date?
        let startTime = Date()

        do {
          let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            return try MLXLMCommon.generate(
              input: lmInput, parameters: parameters, context: context)
          }

          for try await generation in stream {
            switch generation {
            case .chunk(let chunk):
              if firstTokenTime == nil {
                firstTokenTime = Date()
                let ttft = firstTokenTime!.timeIntervalSince(startTime)
                llmLogger.info("Time to first token: \(String(format: "%.3f", ttft))s")
              }

              continuation.yield(chunk)
              fullResponse += chunk
              tokenCount += 1
            case .info, .toolCall:
              break
            }
          }

          let totalDuration = Date().timeIntervalSince(startTime)
          let tokensPerSecond = totalDuration > 0 ? Double(tokenCount) / totalDuration : 0

          llmLogger.info("Streaming generation completed")
          llmLogger.info(
            "Statistics: duration=\(String(format: "%.2f", totalDuration))s, tokens=\(tokenCount), tokens/sec=\(String(format: "%.2f", tokensPerSecond)), response_length=\(fullResponse.count) chars"
          )
          llmLogger.debug("Generated streaming response: \(fullResponse)")
          continuation.finish()
        } catch {
          llmLogger.error("Streaming generation failed: \(error.localizedDescription)")
          continuation.finish()
        }
      }
    }
  }

}

// MARK: - Error Types

enum LLMError: LocalizedError {
  case modelNotFound(String)
  case modelNotLoaded
  case generationFailed(String)
  case invalidInput(String)

  var errorDescription: String? {
    switch self {
    case .modelNotFound(let name):
      return "Model not found: \(name)"
    case .modelNotLoaded:
      return "No model is currently loaded"
    case .generationFailed(let reason):
      return "Generation failed: \(reason)"
    case .invalidInput(let reason):
      return "Invalid input: \(reason)"
    }
  }
}
