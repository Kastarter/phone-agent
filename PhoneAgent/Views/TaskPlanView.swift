import SwiftUI

struct TaskPlanView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var lines = ""
    @State private var error = ""
    @State private var original = ""
    @State private var generating = false
    @State private var request: Task<Void, Never>?
    private enum Field: Hashable { case original, items }
    private enum Prompt: String, Identifiable { case close, remove; var id: String { rawValue } }
    @FocusState private var focusedField: Field?
    @State private var initialOriginal: String?
    @State private var initialLines = ""
    @State private var prompt: Prompt?
    private var hasChanges: Bool { initialOriginal.map { original != $0 || lines != initialLines } ?? false }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Break a complex task into smaller steps. One step per line; they go into the task as a numbered list the agent works through in order.") .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Overall Task & Constraints").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Describe what needs to get done", text: $original, axis: .vertical).lineLimit(3...8).focused($focusedField, equals: .original).agentField().disabled(generating).accessibilityLabel("Overall task and constraints")
                    }
                    Button(generating ? "Cancel" : "Split with AI") {
                        if generating { request?.cancel(); request = nil; generating = false } else { split() }
                    }.buttonStyle(AgentButtonStyle(primary: false))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps · One per Line").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $lines)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220, maxHeight: 360)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .items).agentField().disabled(generating)
                            .accessibilityLabel("Step list")
                        Text("Write one item per line. For example: check tomorrow's calendar, add a grocery reminder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Up to 12 items, 240 characters each.") .font(.footnote).foregroundStyle(.secondary)
                    if !error.isEmpty { AgentNotice(text: error, error: true) }
                    Button("Remove Pending List", role: .destructive) { focusedField = nil; prompt = .remove }.frame(minHeight: 44).disabled(model.taskPlan.isEmpty)
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                Button("Use This List", action: applyPlan).buttonStyle(AgentButtonStyle()).disabled(generating || lines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.horizontal, 20).padding(.vertical, 12).background(AgentPalette.background)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Multi-Step Task").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { focusedField = nil; if hasChanges || generating { prompt = .close } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
                }
        }.tint(AgentPalette.accent).agentSheetStyle().onAppear {
            guard initialOriginal == nil else { return }
            lines = model.taskPlan.joined(separator: "\n")
            original = model.taskPlan.isEmpty ? model.goal : model.taskPlanOriginal
            initialOriginal = original; initialLines = lines
        }
        .interactiveDismissDisabled(hasChanges || generating)
        .onDisappear { request?.cancel() }
        .alert(item: $prompt) { value in
            switch value {
            case .close:
                return Alert(title: Text("List Not Saved"), message: Text("After editing, tap \"Use This List\" at the bottom. Discarding changes also stops any split in progress."), primaryButton: .cancel(Text("Keep Editing")), secondaryButton: .destructive(Text("Discard Changes")) { request?.cancel(); dismiss() })
            case .remove:
                return Alert(title: Text("Remove Pending List?"), message: Text("Keeps the overall task and constraints and removes the step list."), primaryButton: .cancel(), secondaryButton: .destructive(Text("Remove")) { model.removeTaskPlan(); dismiss() })
            }
        }
    }
    private func applyPlan() {
        focusedField = nil
        let items = lines.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (1...12).contains(items.count), items.allSatisfy({ $0.count <= 240 }) else { error = "Enter 1–12 items, each up to 240 characters"; return }
        guard original.count <= 4000 else { error = "The overall task can be up to 4,000 characters"; return }
        model.useTaskPlan(items, original: original); dismiss()
    }
    private func split() {
        guard model.modelReady, model.consentReady else { error = "Set up and authorize the AI service first"; return }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, original.count <= 4000 else { error = "Enter an overall task of 1–4,000 characters"; return }
        error = ""; generating = true
        let settings = model.settings; let key = SettingsStore.apiKey(for: settings.endpoint)
        request = Task {
            do {
                let answer = try await VisionClient(settings: settings, apiKey: key).answer(question: "Split the user task below into steps to run in order. Keep all constraints, and do not add any sending, payment, deletion, or sharing that was not requested. Return only 1–12 lines, one goal per line, with no numbering, explanations, or code blocks, and at most 240 characters per line.\nUser task: " + original, frame: nil, history: [], drafting: true)
                guard !Task.isCancelled else { return }
                let items = answer.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard (1...12).contains(items.count), items.allSatisfy({ $0.count <= 240 && !$0.hasPrefix("```") }) else { throw AgentError.message("The split result isn't in list format; try again or enter it manually") }
                lines = items.joined(separator: "\n"); generating = false; request = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; generating = false; request = nil } }
        }
    }
}
