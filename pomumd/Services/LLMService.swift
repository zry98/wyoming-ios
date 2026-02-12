import Combine
import Foundation
@preconcurrency import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device LLM service using mlx-swift-lm.
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
  private let metricsCollector: MetricsCollector

  // MARK: - Model Management

  private func getModelConfiguration(_ modelID: String) -> ModelConfiguration? {
    LLMRegistry.shared.configuration(id: modelID)
  }

  // MARK: - Initialization

  init(metricsCollector: MetricsCollector) {
    self.metricsCollector = metricsCollector
    // set GPU memory limit to prevent out of memory issues
    Memory.cacheLimit = 20 * 1024 * 1024  // 20 MB
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

  /// Preload a model on app startup for faster first request.
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
    }
  }

  /// Unload the currently loaded model to free memory.
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
    additionalContext: [String: any Sendable]? = nil,
    tools: [[String: any Sendable]]? = nil
  ) async throws -> (String, [ToolCallInfo]) {
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
        case "tool":
          .tool
        default:
          .user
        }
      return Chat.Message(role: role, content: message.content ?? "")
    }

    let toolSpecs: [ToolSpec]? = tools
    let userInput = UserInput(chat: chat, tools: toolSpecs, additionalContext: additionalContext)
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
      var firstTokenTime: Date?

      let stream = try await container.perform { (context: ModelContext) in
        let lmInput = try await context.processor.prepare(input: userInput)
        return try MLXLMCommon.generate(
          input: lmInput, parameters: parameters, context: context)
      }

      var response = ""
      var toolCalls: [ToolCallInfo] = []
      for try await generation in stream {
        switch generation {
        case .chunk(let chunk):
          if firstTokenTime == nil {
            firstTokenTime = Date()
            let ttft = firstTokenTime!.timeIntervalSince(startTime)
            metricsCollector.recordLLMTimeToFirstToken(duration: ttft)
            llmLogger.debug("Time to first token: \(String(format: "%.3f", ttft))s")
          }
          llmLogger.info("chunk: \(chunk)")
          response += chunk
        case .toolCall(let tc):
          llmLogger.info("toolCall: \(tc)")
          let info = self.convertToolCall(tc)
          toolCalls.append(info)
        case .info:
          break
        }
      }

      let duration = Date().timeIntervalSince(startTime)
      let responseTokens = response.split(separator: " ").count
      let tokensPerSecond = duration > 0 ? Double(responseTokens) / duration : 0

      metricsCollector.recordLLMTokensPerSecond(tokensPerSecond)
      if !toolCalls.isEmpty {
        metricsCollector.recordLLMToolCalls(toolCalls.count)
      }

      llmLogger.info("Generation completed successfully")
      llmLogger.info(
        "Statistics: duration=\(String(format: "%.2f", duration))s, tokens=\(responseTokens), tokens/sec=\(String(format: "%.2f", tokensPerSecond)), response_length=\(response.count) chars"
      )
      if !toolCalls.isEmpty {
        llmLogger.info("Tool calls generated: \(toolCalls.count)")
      }
      llmLogger.debug("Generated response: \(response)")
      return (response, toolCalls)
    } catch {
      llmLogger.error("Generation failed: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Tool Call Helpers

  private func convertToolCall(_ tc: MLXLMCommon.ToolCall) -> ToolCallInfo {
    let argsDict = tc.function.arguments.mapValues { $0.anyValue }
    let argsString: String
    if let data = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
      let str = String(data: data, encoding: .utf8)
    {
      argsString = str
    } else {
      argsString = "{}"
    }

    return ToolCallInfo(
      id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))",
      type: "function",
      function: ToolCallInfo.FunctionInfo(
        name: tc.function.name,
        arguments: argsString
      )
    )
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

// MARK: - Extensions

/// Extension providing a default HubApi instance for downloading model files.
extension HubApi {
  /// Default HubApi instance configured to download models to the user's Downloads directory
  /// under a 'huggingface' subdirectory.
  #if os(macOS)
    static let `default` = HubApi(
      downloadBase: URL.downloadsDirectory.appending(path: "huggingface")
    )
  #else
    static let `default` = HubApi(
      downloadBase: URL.cachesDirectory.appending(path: "huggingface")
    )
  #endif
}
