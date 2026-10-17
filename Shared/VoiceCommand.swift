import Foundation

enum VoiceInputMode: String, Identifiable {
    case task, supplement, question
    var id: String { rawValue }
    var title: String {
        switch self { case .task: return "Say your task"; case .supplement: return "Add to the current task"; case .question: return "Chat with the assistant" }
    }
}

enum VoiceCommand: Equatable {
    case pause, handoff, resume, stop, supplement
    static func parse(_ text: String) -> VoiceCommand? {
        var value = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        // Speech recognition may repeat a wake phrase when the speaker pauses.
        // Strip repeated prefixes but still require the rest to be a whole command.
        // Matched against the en-US on-device speech recognizer in VoiceController.
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in ["heyassistant", "assistant", "phoneagent"] where value.hasPrefix(prefix) {
                value.removeFirst(prefix.count); removedPrefix = true; break
            }
        }
        // Match a whole command, so a sentence like "please don't pause" stays task text.
        switch value {
        case "pause", "pausetask", "pausethetask", "pausecurrenttask", "pausethecurrenttask",
             "holdon", "hold", "wait", "pausefornow", "stopforamoment",
             "helpmepause", "helpmepausethetask", "helpmepausethecurrenttask",
             "pleasepause", "pleasepausethetask", "pleasepausethecurrenttask": return .pause
        case "handoff", "takeover", "illtakeover", "letmetakeover", "letmetakethis",
             "illhandleit", "illhandlethis", "illdothis", "illtakethisstep",
             "letmeoperate", "itakeover", "pleasetakeover", "pleasehelpmetakeover": return .handoff
        case "resume", "continue", "continuetask", "continuethetask", "resumetask",
             "continueexecution", "continuecurrenttask", "keepgoing", "goon", "carryon",
             "youcontinue", "readytocontinue", "pleasecontinue", "pleasecontinuethetask": return .resume
        case "stop", "stoptask", "stopthetask", "endtask", "canceltask", "stopexecution",
             "cancelexecution", "terminatetask", "helpmestop", "helpmestopthetask",
             "pleasestop", "pleasestopthetask": return .stop
        case "supplement", "supplementtask", "addrequirement", "addarequirement",
             "addanotherrequirement", "addonemorerequirement", "iwanttoadd", "iwanttoaddarequirement",
             "letmeadd", "addmore", "addtothetask", "addtocurrenttask", "pleasesupplement": return .supplement
        default: return nil
        }
    }
}

enum VoiceTaskRequestRoute: Equatable {
    case start
    case queue
    case busy
}

enum VoiceTaskRequestRouter {
    static func route(
        hasCurrentTask: Bool,
        pendingTaskCount: Int,
        queueRunning: Bool,
        engineRunning: Bool,
        queueSwitching: Bool,
        engineReleasing: Bool,
        voicePending: Bool,
        manualBusy: Bool,
        calibrating: Bool,
        supersede: Bool = false
    ) -> VoiceTaskRequestRoute {
        guard !queueSwitching, !engineReleasing, !voicePending, !manualBusy, !calibrating else { return .busy }
        // A call request is what the user wants now: the caller already stopped the old task, so never queue it.
        if supersede { return engineRunning ? .busy : .start }
        if hasCurrentTask || pendingTaskCount > 0 { return .queue }
        guard !queueRunning, !engineRunning else { return .busy }
        return .start
    }
}
