import SwiftUI

/// LLM model selection view.
struct LLMModelsListView: View {
  @ObservedObject var settingsManager: SettingsManager
  @ObservedObject var llmService: LLMService
  @State private var models: [String] = []
  @State private var sortedModels: [String] = []
  @State private var downloadedModels: Set<String> = []
  @State private var downloadingModel: String?
  @State private var downloadTask: Task<Void, Never>?
  @State private var showDeleteAlert = false
  @State private var modelToDelete: String?

  var body: some View {
    List {
      Section("Tap a model to set it as default, swipe to download / delete") {
        ForEach(sortedModels, id: \.self) { model in
          modelRow(for: model)
        }
      }
    }
    .navigationTitle("LLM Models")
    .onAppear {
      models = llmService.getAvailableModelNames()
      updateSortedModels()
      updateDownloadedModels()
    }
    .onChange(of: models) {
      updateSortedModels()
      updateDownloadedModels()
    }
    .alert("Delete Model", isPresented: $showDeleteAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        if let model = modelToDelete {
          deleteModel(model)
        }
      }
    } message: {
      if let model = modelToDelete {
        Text("Are you sure you want to delete \(model)? This will remove all downloaded files.")
      }
    }
  }

  @ViewBuilder
  private func modelRow(for model: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(model)

        if downloadingModel == model {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              ProgressView(value: llmService.downloadProgress, total: 1.0)
                .frame(maxWidth: 150)
              Text("\(Int(llmService.downloadProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
              Button {
                cancelDownload(model)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundColor(.red)
                  .font(.caption)
              }
              .buttonStyle(.plain)
            }
          }
        } else if downloadedModels.contains(model) {
          HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
              .font(.caption)
              .foregroundColor(.green)
            Text("Downloaded")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }

      Spacer()

      if settingsManager.defaultLLMModel == model {
        Image(systemName: "checkmark")
          .foregroundColor(.blue)
      }

      #if os(macOS)
        Menu {
          if downloadedModels.contains(model) {
            Button(role: .destructive) {
              modelToDelete = model
              showDeleteAlert = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          } else {
            Button {
              downloadModel(model)
            } label: {
              Label("Download", systemImage: "arrow.down.circle")
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundColor(.blue)
        }
        .buttonStyle(.plain)
      #endif
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture {
      // only allow setting as default if the model is downloaded
      guard downloadedModels.contains(model) else {
        return
      }

      if settingsManager.defaultLLMModel == model {
        settingsManager.defaultLLMModel = ""
      } else {
        settingsManager.defaultLLMModel = model
      }
    }
    #if os(iOS)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if downloadedModels.contains(model) {
          Button(role: .destructive) {
            modelToDelete = model
            showDeleteAlert = true
          } label: {
            Label("Delete", systemImage: "trash")
          }
        } else {
          Button {
            downloadModel(model)
          } label: {
            Label("Download", systemImage: "arrow.down.circle")
          }
          .tint(.blue)
        }
      }
    #endif
  }

  private func updateSortedModels() {
    sortedModels = models.sorted { m1, m2 in
      return m1.localizedCaseInsensitiveCompare(m2) == .orderedAscending
    }
  }

  private func updateDownloadedModels() {
    downloadedModels = Set(models.filter { llmService.isModelDownloaded($0) })
  }

  private func downloadModel(_ modelName: String) {
    downloadingModel = modelName
    downloadTask = Task {
      do {
        _ = try await llmService.loadModel(modelName)
        await MainActor.run {
          downloadingModel = nil
          downloadTask = nil
          updateDownloadedModels()
        }
      } catch {
        await MainActor.run {
          downloadingModel = nil
          downloadTask = nil
        }
        print("Failed to download model: \(error.localizedDescription)")
      }
    }
  }

  private func cancelDownload(_ modelName: String) {
    llmService.cancelDownload(modelName)

    downloadTask?.cancel()
    downloadTask = nil
    downloadingModel = nil

    // delete partially downloaded files
    Task {
      do {
        try await llmService.deleteModel(modelName)
        await MainActor.run {
          updateDownloadedModels()
        }
      } catch {
        print("Failed to delete partial download: \(error.localizedDescription)")
      }
    }
  }

  private func deleteModel(_ modelName: String) {
    Task {
      do {
        // unset as default
        if settingsManager.defaultLLMModel == modelName {
          await MainActor.run {
            settingsManager.defaultLLMModel = ""
          }
        }

        try await llmService.deleteModel(modelName)
        await MainActor.run {
          updateDownloadedModels()
          modelToDelete = nil
        }
      } catch {
        print("Failed to delete model: \(error.localizedDescription)")
      }
    }
  }
}
