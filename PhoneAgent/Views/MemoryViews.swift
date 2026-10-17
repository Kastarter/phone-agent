import SwiftUI
import UniformTypeIdentifiers

struct MemoryEditorSeed: Identifiable {
    var value: AssistantMemory
    var image: UIImage? = nil
    var id: UUID { value.id }
}
struct MemoryEditor: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State var seed: MemoryEditorSeed
    @State private var keepImage = false
    @State private var error = ""
    private enum Field: Hashable { case title, content }
    @FocusState private var focusedField: Field?
    @State private var originalValue: AssistantMemory?
    @State private var originalKeepImage = false
    @State private var confirmingClose = false
    private var hasChanges: Bool {
        guard let originalValue else { return false }
        return seed.value != originalValue || keepImage != originalKeepImage
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Name this memory", text: $seed.value.title).focused($focusedField, equals: .title).agentField().accessibilityLabel("Memory title")
                    }
                    Picker("Type", selection: $seed.value.kind) { ForEach(MemoryKind.allCases) { Text($0.displayName).tag($0) } }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Write it down, or summarize your preference", text: $seed.value.text, axis: .vertical).lineLimit(6...20).focused($focusedField, equals: .content).agentField().accessibilityLabel("Memory content")
                    }
                    Text("Source: \(seed.value.source)").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Allow Use in Related Tasks", isOn: $seed.value.enabled).tint(AgentPalette.accent)
                    Text("Saved on this device. Related text is sent with chat questions only when \"Use On-Device Memory\" is on and the current AI service is authorized. Saved images are never sent automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let image = seed.image ?? model.memories.image(for: seed.value) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 18))
                        Toggle("Save This Image", isOn: $keepImage).tint(AgentPalette.accent)
                    }
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { focusedField = nil; if hasChanges { confirmingClose = true } else { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityLabel("Save memory to this device") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle()
            .onAppear { if originalValue == nil { keepImage = seed.value.imageName != nil; originalKeepImage = keepImage; originalValue = seed.value } }
            .interactiveDismissDisabled(hasChanges)
            .alert("Memory Not Saved", isPresented: $confirmingClose) {
                Button("Keep Editing", role: .cancel) { }
                Button("Discard Changes", role: .destructive) { dismiss() }
            } message: { Text("Keep editing, then tap \"Save\" at the top right to keep it on this device.") }
    }
    private func save() {
        focusedField = nil
        do {
            var value = seed.value
            if !keepImage { value.imageName = nil }
            try model.memories.save(value, image: keepImage ? seed.image : nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @State private var exporting = false
    @State private var exportDocument: ArtifactDocument?
    @State private var query = ""
    @State private var result = MemorySearchResult(hits: [], semantic: false)
    @State private var searching = false
    @State private var editor: MemoryEditorSeed?
    @State private var delete: AssistantMemory?
    @State private var clear = false
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Save Your Preferences").font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("Export Memory Text & Index") {
                            do { exportDocument = ArtifactDocument(data: try model.memories.exportText()); exporting = true }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("Clear All Memories", role: .destructive) { clear = true }
                            .disabled(model.memories.records.isEmpty && model.memories.error.isEmpty)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Manage memories")
                    Button { editor = MemoryEditorSeed(value: AssistantMemory(title: "", text: "")) } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44).agentGlass(in: Circle(), interactive: true)
                    }.accessibilityLabel("New memory")
                }
                Toggle("Use On-Device Memory", isOn: Binding(get: { model.settings.useMemories == true }, set: { model.settings.useMemories = $0 })).tint(AgentPalette.accent)
                Text("When on, each chat question includes text from up to 3 related memories, sent to the AI service you configured and authorized. When off, you can still search on device.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Search by content or meaning", text: $query).agentField()
                if searching { ProgressView() }
                else if !query.isEmpty { Text(result.semantic ? "Using on-device semantic and keyword search" : "This device uses keyword search").font(.caption).foregroundStyle(.secondary) }
                if !model.memories.error.isEmpty { AgentNotice(text: model.memories.error, error: true) }
                if !error.isEmpty { AgentNotice(text: error, error: true) }
                let items = query.isEmpty ? model.memories.records : result.hits.map(\.memory)
                if items.isEmpty { AgentEmptyState(title: query.isEmpty ? "No Memories Yet" : "No Matches", detail: "Write down a preference, or save an answer from a chat.", icon: "bookmark") }
                ForEach(items) { memory in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(memory.title).font(.headline); Spacer(); if !memory.enabled { Image(systemName: "eye.slash").accessibilityLabel("Not used") } }
                        Text(memory.text).lineLimit(3).foregroundStyle(.secondary)
                        Text("\(memory.kind.displayName) · \(memory.updatedAt.formatted(date: .abbreviated, time: .omitted)) · \(memory.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.agentPanel().contentShape(Rectangle())
                        .onTapGesture { editor = MemoryEditorSeed(value: memory) }
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                        .accessibilityAction { editor = MemoryEditorSeed(value: memory) }
                        .contextMenu {
                            Button("View & Edit") { editor = MemoryEditorSeed(value: memory) }
                            Button("Delete", role: .destructive) { delete = memory }
                        }
                }
                AgentHelp(title: "About Exports", text: "The exported JSON doesn't include image files; saved images stay on this device.")
            }.padding(20)
        }
        .task(id: query + model.memories.records.map { $0.updatedAt.description }.joined()) {
            searching = true
            let value = await model.memories.search(query)
            guard !Task.isCancelled else { return }; result = value; searching = false
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Phone Agent Memory.json") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }; exportDocument = nil
        }
        .sheet(item: $editor) { MemoryEditor(seed: $0) }
        .confirmationDialog("Delete this memory?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let delete { do { try model.memories.remove(delete.id) } catch { self.error = error.localizedDescription } }; delete = nil }
        }
        .confirmationDialog("Clear on-device memories and saved images?", isPresented: $clear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { do { try model.memories.clear() } catch { self.error = error.localizedDescription } }
        } message: { Text("This can't be undone and doesn't delete data AI services have already received.") }
    }
}
