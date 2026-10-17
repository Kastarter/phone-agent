import Foundation
import Combine

struct AssistantMessage: Identifiable, Codable {
    var id = UUID()
    var role: String
    var text: String
    var createdAt = Date()
    var screenDate: Date? = nil
    var cameraFrames: Int? = nil
    var cameraDuration: TimeInterval? = nil
}

@MainActor
final class AssistantConversation: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var selectedFrame: ScreenFrame?
    private var selectedSequence: [CameraObservationFrame] = []
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var recipient = ""
    func selectFrame(_ frame: ScreenFrame?) { selectedFrame = frame; selectedSequence = [] }
    func selectSequence(_ frames: [CameraObservationFrame]) { selectedFrame = nil; selectedSequence = frames }
    func cancel() {
        generation = UUID(); request?.cancel(); request = nil
        if loading, messages.last?.role == "user" {
            if draft.isEmpty { draft = messages.last?.text ?? "" }
            messages.removeLast()
        }
        loading = false
    }
    func clear() { cancel(); messages = []; draft = ""; selectedFrame = nil; selectedSequence = []; error = "" }
    @discardableResult
    func send(settings: AgentSettings, apiKey: String, memories: MemoryStore, observationContext: String = "") -> Bool {
        guard !loading else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { error = "Enter a question of 1–4,000 characters"; return false }
        guard PrivacyConsent.allowed(settings) else { error = "First confirm sending your question and selected frames to the current AI service"; return false }
        let key = settings.endpoint + "|" + PrivacyConsent.recipient(settings) + "|" + settings.model
        if recipient != key { messages = []; recipient = key }
        let frame = selectedFrame
        let sequence = selectedSequence
        let recent = Array(messages.suffix(12))
        messages.append(AssistantMessage(role: "user", text: text, screenDate: frame?.capturedAt ?? sequence.last?.capturedAt,
                                        cameraFrames: sequence.isEmpty ? nil : sequence.count,
                                        cameraDuration: sequence.isEmpty ? nil : (sequence.last!.capturedUptime - sequence.first!.capturedUptime)))
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        draft = ""; error = ""; loading = true; let token = UUID(); generation = token
        request = Task { [weak self] in
            do {
                var context = settings.useMemories == true ? await memories.context(for: text) : ""
                if !sequence.isEmpty, !observationContext.isEmpty { context += "\nRecent camera observation notes (unverified historical reference only):\n" + String(observationContext.prefix(1000)) }
                try Task.checkCancellation()
                let answer = try await VisionClient(settings: settings, apiKey: apiKey).answer(question: text, frame: frame, history: recent, memoryContext: context, sequence: sequence)
                try Task.checkCancellation()
                guard let self, token == self.generation else { return }
                self.messages.append(AssistantMessage(role: "assistant", text: answer))
                self.loading = false; self.request = nil
            } catch is CancellationError {
                // No cancelled response may update a newer conversation.
            } catch {
                guard let self, token == self.generation else { return }
                self.loading = false; self.request = nil; self.draft = text; self.error = error.localizedDescription
                if self.messages.last?.role == "user" { self.messages.removeLast() }
            }
        }
        return true
    }
}
