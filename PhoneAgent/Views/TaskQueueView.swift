import SwiftUI
import UniformTypeIdentifiers

struct TaskQueueView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clear = false
    @State private var removing: UUID?
    @State private var exporting = false
    @State private var document: ArtifactDocument?
    @State private var error = ""
    private var locked: Bool { model.queueRunning || model.queueSwitching || model.engine.releasing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Run tasks in order").font(.title2.weight(.semibold)); Spacer()
                    Menu {
                        Button("Export Queue") {
                            do { document = ArtifactDocument(data: try model.taskQueue.exportData()); exporting = true }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("Clear Queue", role: .destructive) { clear = true }.disabled(locked || model.engine.running)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.buttonStyle(.glass).accessibilityLabel("Queue options")
                }
                Text(model.queueStatus).font(.subheadline.weight(.medium))
                AgentHelp(title: "How the queue works", text: "After one task finishes, the next one starts in order. Jumping the queue saves the current task, which resumes from a fresh screen after the priority task finishes. If a task pauses, needs you, or hits an error, the whole queue waits for your confirmation. The queue does not run automatically after reopening the app. The next task starts only in the foreground; removing items does not undo actions already taken.")
                if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Home draft").font(.subheadline.weight(.semibold))
                        Text(model.goal).font(.subheadline).lineLimit(3).foregroundStyle(.secondary)
                        Button("Add Home Draft") { model.enqueueDraft() }
                            .buttonStyle(AgentButtonStyle(primary: false))
                            .disabled(locked || model.voicePending || model.calibrating || model.manualBusy || model.executor.calibrationInProgress || model.taskQueue.items.count >= 20)
                        Text("Adds to the queue only; nothing runs until you tap “Run Queue”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.agentPanel()
                }
                if !model.notice.isEmpty { AgentNotice(text: model.notice) }
                if !model.taskQueue.error.isEmpty { AgentNotice(text: model.taskQueue.error, error: true) }
                if !error.isEmpty { AgentNotice(text: error, error: true) }
                if model.taskQueue.items.isEmpty {
                    AgentEmptyState(title: "No queued tasks yet", detail: "Write a task on the home screen, then add it to the queue. Up to 20 items.", icon: "list.bullet")
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(model.taskQueue.items.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index)
                        }
                    }
                }
            }.padding(20)
        }.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3), value: model.taskQueue.items.map(\.id))
            .safeAreaBar(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if model.queueSwitching { ProgressView("Switching tasks…").frame(maxWidth: .infinity, minHeight: 48) }
                    else if model.queueRunning { Button("Pause Queue") { model.pauseQueue() }.buttonStyle(AgentButtonStyle()) }
                    else { Button("Run Queue") { model.runTaskQueue() }.buttonStyle(AgentButtonStyle()).disabled(model.taskQueue.pendingCount == 0 || model.engine.releasing || model.calibrating || model.manualBusy || model.voicePending) }
                }.padding(.horizontal, 24).padding(.vertical, 10)
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Phone Agent Task Queue.json") { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }; document = nil
            }
            .confirmationDialog("Clear the task queue on this device?", isPresented: $clear, titleVisibility: .visible) {
                Button("Clear Queue", role: .destructive) { model.clearTaskQueue() }
            } message: { Text("Deletes waiting items and saved progress. Actions already taken on the phone are not undone, and task history and tool receipts are kept. A paused task can still be resumed manually from the home screen.") }
            .confirmationDialog("Remove this queued task?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let id = removing { model.removeQueuedTask(id) }; removing = nil }
            } message: { Text("Actions already taken and task history are not undone.") }
    }
    private func queueRow(_ item: QueuedPhoneTask, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, height: 24)
                Text(item.record.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu {
                    Button("Move Up") { model.moveQueuedTask(item.id, by: -1) }.disabled(locked || index == 0)
                    Button("Move Down") { model.moveQueuedTask(item.id, by: 1) }.disabled(locked || index == model.taskQueue.items.count - 1)
                    Button("Use Current Settings") { model.useCurrentQueueConfiguration(item.id) }.disabled(locked || !item.resumable || model.engine.running)
                    Button("Remove", role: .destructive) { removing = item.id }.disabled(locked || (model.engine.currentRecord?.id == item.id && model.engine.hasCurrentTask))
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Queue options for \(item.record.title)")
            }
            Text(item.record.effectiveGoal).font(.subheadline).lineLimit(4)
            Label(item.state.label, systemImage: item.state == .completed ? "checkmark.circle" : item.state == .running ? "circle.dotted" : "clock")
                .font(.caption).foregroundStyle(item.state == .completed ? Color.green : .secondary)
            Text("\(PrivacyConsent.recipient(item.settings)) · \(item.settings.model)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if item.started { Text("Reached step \(item.step)").font(.caption).foregroundStyle(.secondary) }
            if !item.note.isEmpty { Text(item.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if item.resumable && item.state != .running {
                Button(model.engine.running ? "Run This Next" : item.started ? "Review and Continue" : "Run This") { model.runTaskQueue(first: item.id) }
                    .buttonStyle(AgentButtonStyle(primary: false))
                    .disabled(model.queueSwitching || model.engine.releasing || model.calibrating || model.manualBusy || model.voicePending)
            }
        }.agentPanel()
    }
}
