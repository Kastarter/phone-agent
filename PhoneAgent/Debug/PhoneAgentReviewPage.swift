import SwiftUI

#if DEBUG
// Visual-only launch routes. Never start hardware, permissions, or network work.
struct PhoneAgentReviewPage: View {
    let name: String
    @EnvironmentObject private var model: PhoneAgentViewModel
    private var recording: LocalRecording {
        model.recordings.records.first ?? .init(id: UUID(), title: "Product Discussion", createdAt: Date(), updatedAt: Date(), duration: 180, interrupted: false)
    }
    private var meeting: MeetingEditorSeed {
        let source = "Finish the home page design by Friday. Review the interaction flow next week."
        var notes = MeetingNotes.empty(title: "Product Discussion")
        notes.summary = .init(text: "Finish the home page design and prepare the interaction review.", quote: source)
        notes.points = [.init(text: "Finish the home page design by Friday", quote: "Finish the home page design by Friday.")]
        notes.actions = [.init(text: "Review the interaction flow", quote: "Review the interaction flow next week.", owner: nil, due: "Next week")]
        return .init(source: source, sourceName: "Meeting Notes", notes: notes)
    }
    var body: some View {
        page.tint(AgentPalette.accent).background(AgentPalette.background)
    }
    @ViewBuilder private var page: some View {
        switch name {
        case "settings": SettingsView(onBack: {})
        case "task": TaskDetailView(id: model.history.records.first?.id ?? UUID())
        case "conversation": ContentView(reviewConversation: model.history.records.first?.id)
        case "device": ContentView(reviewDestination: .device)
        case "share": ContentView(reviewDestination: .screenShare)
        case "assistant": ContentView(reviewDestination: .assistant)
        case "memory": ContentView(reviewDestination: .memory)
        case "workbench": ContentView(reviewDestination: .workbench)
        case "queue": ContentView(reviewDestination: .queue)
        case "voice", "voice-listening": ContentView(reviewVoice: .listening)
        case "voice-preparing": ContentView(reviewVoice: .preparing)
        case "voice-finalizing": ContentView(reviewVoice: .finalizing)
        case "voice-error": ContentView(reviewVoice: .idle, reviewVoiceError: "Speech recognition interrupted; recognized text kept")
        case "assistant-voice": ContentView(reviewDestination: .assistant, reviewVoice: .listening)
        case "memory-editor": MemoryEditor(seed: .init(value: .init(title: "My Preference", text: "Prefer short, clear English replies.")))
        case "realtime": RealtimeView()
        case "recordings": RecordingsView(store: model.recordings) { _ in }
        case "speaker": SpeakerView(record: recording, store: model.recordings) { _ in }
        case "meeting": MeetingNotesView(seed: meeting, onApply: { _ in }, onRetainDraft: { _ in })
        case "spreadsheet": SpreadsheetView(seed: .init(title: "Plan", text: "Item\tStatus\nHome page design\tDone\nInteraction review\tTo do"))
        case "search": WebSearchView()
        case "search-settings": NavigationStack { WebSearchSettingsView().navigationTitle("Search Service").navigationBarTitleDisplayMode(.inline) }
        case "research": WebInvestigationView(initialQuestion: "")
        case "webpage": WebPageView(source: .init(id: 1, title: "Read Source", url: URL(string: "https://example.com/article")!, excerpt: "", publishedLabel: nil, excerptShortened: false), onUse: { _ in })
        case "plan": TaskPlanView()
        case "preparation": PreparationView(navigate: { _ in })
        case "policy": DataPolicyView()
        case "consent": DataConsentView(onDecision: {})
        case "calibration": CalibrationView(model: .init(executor: model.executor))
        default:
            if name.hasPrefix("settings-") { SettingsView(reviewPage: String(name.dropFirst(9)), onBack: {}) }
            else { ContentView() }
        }
    }
}
#endif
