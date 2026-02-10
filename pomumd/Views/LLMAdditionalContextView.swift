import SwiftUI

/// LLM additional context (KV pairs) settings view.
struct LLMAdditionalContextView: View {
  @ObservedObject var settingsManager: SettingsManager
  @State private var showingAddSheet = false
  @State private var newKey = ""
  @State private var newValue = ""
  @State private var newType: LLMAdditionalContextItem.ValueType = .string
  @State private var editingItem: LLMAdditionalContextItem?

  var body: some View {
    List {
      Section("Additional Context Parameters") {
        ForEach(settingsManager.defaultLLMAdditionalContext) { item in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(item.key)
                .font(.body)
              HStack(spacing: 8) {
                Text(item.value)
                  .font(.caption)
                  .foregroundColor(.secondary)
                Text("(\(item.type.displayName))")
                  .font(.caption)
                  .foregroundColor(.blue)
              }
            }

            Spacer()

            Button(action: {
              editingItem = item
              newKey = item.key
              newValue = item.value
              newType = item.type
              showingAddSheet = true
            }) {
              Image(systemName: "pencil")
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
          }
          .padding(.vertical, 4)
        }
        .onDelete(perform: deleteItems)

        Button(action: {
          editingItem = nil
          newKey = ""
          newValue = ""
          newType = .string
          showingAddSheet = true
        }) {
          HStack {
            Image(systemName: "plus.circle.fill")
            Text("Add Parameter")
          }
        }
      }

      Section {
        Button(action: {
          settingsManager.defaultLLMAdditionalContext = []
        }) {
          HStack {
            Spacer()
            Text("Clear All Parameters")
              .fontWeight(.semibold)
              .foregroundColor(.red)
            Spacer()
          }
        }
      }
    }
    .navigationTitle("LLM Additional Context")
    .sheet(isPresented: $showingAddSheet) {
      addEditSheet
    }
  }

  private var isValidValue: Bool {
    switch newType {
    case .string:
      return true
    case .bool:
      return newValue.lowercased() == "true" || newValue.lowercased() == "false"
    case .number:
      return Double(newValue) != nil
    }
  }

  private var addEditSheet: some View {
    #if os(macOS)
      macOSSheet
    #else
      iOSSheet
    #endif
  }

  private var macOSSheet: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button("Cancel") {
          showingAddSheet = false
        }

        Spacer()

        Text(editingItem == nil ? "Add Parameter" : "Edit Parameter")
          .font(.headline)

        Spacer()

        Button("Save") {
          saveParameter()
          showingAddSheet = false
        }
        .disabled(newKey.isEmpty || newValue.isEmpty || !isValidValue)
      }
      .padding()
      .background(Color(NSColor.windowBackgroundColor))

      Divider()

      formContent
        .padding([.horizontal, .vertical])
    }
    .frame(width: 450, height: 450, alignment: .top)
  }

  private var iOSSheet: some View {
    NavigationView {
      formContent
        .navigationTitle(editingItem == nil ? "Add Parameter" : "Edit Parameter")
        .inlineNavigationBarTitle()
        .navigationBarItems(
          leading: Button("Cancel") {
            showingAddSheet = false
          },
          trailing: Button("Save") {
            saveParameter()
            showingAddSheet = false
          }
          .disabled(newKey.isEmpty || newValue.isEmpty || !isValidValue)
        )
    }
  }

  private var formContent: some View {
    Form {
      Section {
        TextField("Key", text: $newKey)
        TextField("Value", text: $newValue)

        Picker("Type", selection: $newType) {
          ForEach(LLMAdditionalContextItem.ValueType.allCases, id: \.self) { type in
            Text(type.displayName).tag(type)
          }
        }
      }

      if !isValidValue {
        Section {
          Text("Invalid value for \(newType.displayName) type")
            .font(.caption)
            .foregroundColor(.red)
        }
      }
    }
  }

  private func saveParameter() {
    var items = settingsManager.defaultLLMAdditionalContext

    // if editing, remove the old item first
    if let editingItem = editingItem {
      items.removeAll { $0.id == editingItem.id }
    }

    let newItem = LLMAdditionalContextItem(
      key: newKey,
      value: newValue,
      type: newType
    )
    items.append(newItem)

    settingsManager.defaultLLMAdditionalContext = items
  }

  private func deleteItems(at offsets: IndexSet) {
    var items = settingsManager.defaultLLMAdditionalContext
    items.remove(atOffsets: offsets)
    settingsManager.defaultLLMAdditionalContext = items
  }
}
