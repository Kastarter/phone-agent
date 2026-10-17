import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var controlGlass
    @State private var showActions = false
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false
    let id: UUID
    private var current: Bool { model.engine.currentRecord?.id == id }
    private var record: PhoneTaskRecord? { model.history.records.first { $0.id == id } ?? (current ? model.engine.currentRecord : nil) }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let record {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(record.title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Label(record.outcome.label, systemImage: record.outcome == .completed ? "checkmark.circle" : "circle.dotted")
                            .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 10)
                            .agentGlass(in: Capsule())
                        Text(record.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        AgentCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Task").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                Text(record.goal).font(.body).textSelection(.enabled)
                                ForEach(record.amendments ?? []) { addition in
                                    Divider()
                                    Text("Added · \(addition.createdAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(addition.text).textSelection(.enabled)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(current && model.engine.running ? "In Progress" : "Result").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(current ? model.engine.state : record.summary).font(.title3.weight(.medium))
                            if current, let action = model.engine.pendingAction { Text(action.reason).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        if current, !model.engine.error.isEmpty { AgentNotice(text: model.engine.error, error: true) }
                        DisclosureGroup("Action Log · \(record.logs.count)", isExpanded: $showActions) {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(record.logs) { log in
                                    HStack(alignment: .top, spacing: 12) {
                                        Text("\(log.step)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 28, height: 28).background(AgentPalette.surface, in: Circle())
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack { Text(log.title).font(.subheadline.weight(.semibold)); Spacer(); Text(log.date, style: .time).font(.caption2).foregroundStyle(.tertiary) }
                                            Text(log.detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.padding(.top, 10)
                                }
                            }
                        }.font(.subheadline)
                    }.padding(20)
                } else { Text("This task was deleted").padding(20) }
            }.navigationTitle("Task Details").navigationBarTitleDisplayMode(.inline).scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if let record {
                    VStack(spacing: 12) {
                        if current && (model.engine.running || model.engine.canResume || model.engine.releasing) { controls }
                        else if !model.engine.running && !model.engine.releasing {
                            Button("Use as New Task") {
                                if !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.goal != record.effectiveGoal { model.notice = "There's an unsent task in the input box. Handle that draft first." }
                                else { model.goal = record.effectiveGoal }
                                dismiss()
                            }.buttonStyle(AgentButtonStyle())
                            if record.outcome != .completed { Text("The new task plans from scratch. The last run may have partly finished, so remove anything that doesn't need redoing. The old run won't resume automatically.") .font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Rename") { title = record?.title ?? ""; renaming = true }
                        Button("Delete Task", role: .destructive) { deleting = true }.disabled(model.engine.running || model.engine.releasing)
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Task options")
                }
            }
            .alert("Task Name", isPresented: $renaming) {
                TextField("Name", text: $title)
                Button("Save") {
                    if current { model.engine.renameCurrent(title) }
                    else { model.history.rename(id, title: title) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this task and its action log?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) { model.removeTask(id); dismiss() }
            }
        }.tint(AgentPalette.accent).agentSheetStyle()
    }
    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 12) {
                if model.engine.phase == .awaitingApproval {
                    Button("Run This Step") { model.engine.approve() }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("approve", in: controlGlass)
                }
                if model.engine.running {
                    HStack(spacing: 12) {
                        Button("Pause Task") { model.pauseTask() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("continue", in: controlGlass)
                            .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        Button("Stop", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                            .glassEffectID("stop", in: controlGlass)
                    }
                    Button("Take Over and Add") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                } else if model.engine.canResume {
                    Button("Add Instructions") { model.beginVoice(.supplement) }.buttonStyle(AgentButtonStyle(primary: false))
                    Button(model.engine.phase == .needsUser ? "Done, Continue Task" : "Continue Task") { model.resumeAgent() }.buttonStyle(AgentButtonStyle())
                        .glassEffectID("continue", in: controlGlass)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                    Button("End Task", role: .destructive) { model.stop() }.buttonStyle(AgentButtonStyle(primary: false))
                        .glassEffectID("stop", in: controlGlass)
                } else if model.engine.releasing {
                    ProgressView("Releasing input…").padding(16).frame(maxWidth: .infinity)
                        .agentGlass(in: RoundedRectangle(cornerRadius: 20))
                        .glassEffectID("continue", in: controlGlass)
                }
            }
        }.animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.phase)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32), value: model.engine.releasing)
    }
}
