import SwiftUI
import UIKit

/// Keyboard check: the accessory types every US key, plain and with Shift, into a hidden field of Phone Agent,
/// and what iOS inserts is the map for the active input source (English or Arabic, told apart by the letters).
@MainActor
final class KeyboardCheckModel: ObservableObject {
    typealias Script = KeyboardLayouts.Script
    @Published var text = "Learns what each keyboard types for the accessory's keys. Keep Phone Agent in front and don't type during the check."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var error = ""
    @Published var focused = false
    @Published private(set) var learned = KeyboardLayouts.load()
    @Published private(set) var lastLearned: Script?
    let executor: MouseExecutor
    private var received: [String] = []
    private var receivedAt = 0.0
    private var task: Task<Void, Never>?
    static let keys = KeyboardLayouts.probeUsages.flatMap { [KeyboardLayouts.Key(0, $0), KeyboardLayouts.Key(KeyboardLayouts.shift, $0)] }
    init(executor: MouseExecutor) { self.executor = executor }

    /// English is the standard US layout, built in; only other keyboards need learning.
    var missing: Script? { Script.allCases.first { $0 != .latin && learned[$0] == nil } }
    var action: String { lastLearned == nil ? "Start Check" : missing != nil ? "Continue" : "Check Again" }

    func receive(_ s: String) { received.append(s); receivedAt = brainNow() }

    func cancel() {
        task?.cancel(); focused = false
    }

    /// Learns the active source; the next run (after a 🌐 switch) learns the other one.
    func start() {
        guard !busy else { return }
        let ble = executor.ble
        guard ble.keyboardReady else { error = "Connect AgentMouse and wait for “Bluetooth keyboard ready”, then try again."; return }
        guard ble.status?.capsLock != true else { error = "Turn Caps Lock off, then start again."; return }
        error = ""; busy = true; progress = 0; focused = true
        text = "Typing \(Self.keys.count) keys into a hidden field…"
        task = Task {
            do {
                try await Task.sleep(nanoseconds: 400_000_000)  // the field takes focus
                let samples = try await learnKeys()
                guard let layout = KeyboardLayouts.learn(samples) else {
                    throw AgentError.message("No letters arrived. Keep Phone Agent in front with the accessory's keyboard connected, and try again.")
                }
                // Asked to switch but the same keyboard answered: iOS kept the previous input source for this field.
                if let wanted = missing, let previous = lastLearned, layout.script == previous, wanted != previous {
                    throw AgentError.message("The keyboard is still \(previous.name). Tap 🌐 on the on-screen keyboard until it shows \(wanted.name), then tap Continue.")
                }
                KeyboardLayouts.save(layout); learned[layout.script] = layout; lastLearned = layout.script
                text = missing.map { "Learned \(layout.script.name) (\(layout.keys.count) keys). Now switch the keyboard to \($0.name) with the 🌐 key, then tap Continue." }
                    ?? "Learned \(layout.script.name). Typing works in English (built-in layout) and Arabic."
                if missing == nil { focused = false }
            } catch is CancellationError {
                text = "Keyboard check cancelled"
            } catch {
                self.error = error.localizedDescription; text = "Keyboard check failed"
            }
            if Task.isCancelled { await Task { @MainActor in await executor.ble.release() }.value }
            busy = false; task = nil
        }
    }

    /// Every key in one sequence: one insertion per key, in order. If a key typed nothing (or two insertions
    /// arrived), the keys go one at a time instead.
    private func learnKeys() async throws -> [(KeyboardLayouts.Key, String)] {
        let keys = Self.keys
        received = []
        try await executor.ble.typeKeys(keys.map { ($0.modifier, $0.usage) })
        progress = 0.5
        try await quiet()
        if received.count == keys.count { progress = 1; return Array(zip(keys, received)) }
        var samples: [(KeyboardLayouts.Key, String)] = []
        for (i, key) in keys.enumerated() {
            received = []
            try await executor.ble.typeKeys([(key.modifier, key.usage)])
            let deadline = brainNow() + 0.15
            while received.isEmpty && brainNow() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            samples.append((key, received.joined()))
            progress = 0.5 + 0.5 * Double(i + 1) / Double(keys.count)
        }
        return samples
    }

    /// Until no insertion arrived for 0.3 s.
    private func quiet() async throws {
        receivedAt = max(receivedAt, brainNow())
        while brainNow() - receivedAt < 0.3 { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}

struct KeyboardCheckView: View {
    @StateObject var model: KeyboardCheckModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            KeyCatcher(focused: model.focused) { model.receive($0) }
                .frame(width: 1, height: 1).opacity(0.02).accessibilityHidden(true)
            VStack {
                Spacer()
                VStack(spacing: 13) {
                    HStack(spacing: 10) {
                        AgentOrb(size: 35)
                        Text("Keyboard Check").font(.title3.weight(.semibold))
                    }
                    Text(model.text).font(.subheadline).multilineTextAlignment(.center)
                    if model.busy { ProgressView(value: model.progress) }
                    VStack(spacing: 6) {
                        ForEach(KeyboardLayouts.Script.allCases, id: \.self) { script in
                            HStack {
                                Label(script.name, systemImage: model.learned[script] == nil && script != .latin ? "circle" : "checkmark.circle.fill")
                                Spacer()
                                Text(model.learned[script].map { "\($0.keys.count) keys · \($0.learnedAt.formatted(date: .abbreviated, time: .omitted))" } ?? (script == .latin ? "Built-in (US layout)" : "Not learned"))
                                    .foregroundStyle(.secondary)
                            }.font(.footnote.monospacedDigit())
                        }
                    }
                    if !model.error.isEmpty { AgentNotice(text: model.error, error: true) }
                    Text("The accessory types \(KeyboardCheckModel.keys.count) keys, with and without Shift, into a hidden field: a few seconds per keyboard.\nRun it once per keyboard; switch with the 🌐 key in between.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 10) {
                            Button(model.action) { model.start() }.buttonStyle(AgentButtonStyle()).disabled(model.busy)
                            Button("Done") { model.cancel(); dismiss() }.buttonStyle(AgentButtonStyle(primary: false))
                        }
                    }
                }.padding(20).frame(maxWidth: 390).agentGlass(in: RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }.tint(AgentPalette.accent).onDisappear { model.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel() } }
    }
}

/// A focused, nearly invisible text field that reports every insertion and keeps itself empty.
private struct KeyCatcher: UIViewRepresentable {
    let focused: Bool
    let onText: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no; field.autocapitalizationType = .none; field.spellCheckingType = .no
        field.smartQuotesType = .no; field.smartDashesType = .no; field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no; field.tintColor = .clear; field.textColor = .clear
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onText = onText
        DispatchQueue.main.async {
            if focused, !field.isFirstResponder { field.becomeFirstResponder() }
            if !focused, field.isFirstResponder { field.resignFirstResponder() }
        }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        init(onText: @escaping (String) -> Void) { self.onText = onText }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if !string.isEmpty { onText(string) }
            return false
        }
    }
}
