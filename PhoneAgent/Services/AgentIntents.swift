import Foundation
import AppIntents

struct StartCurrentPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Current Phone Task"
    static let description = IntentDescription("Runs the current task saved in Phone Agent.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestVoiceTask(PhoneAgentViewModel.shared.goal)
        return .result(dialog: "\(message)")
    }
}

struct RunPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Phone Task"
    static let description = IntentDescription("Sends a text task to Phone Agent. Use it with a fixed phrase or to receive dictation.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Task", requestValueDialog: "What do you want the phone to do?")
    var task: String

    static var parameterSummary: some ParameterSummary { Summary("Run phone task \(\.$task)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestVoiceTask(task)
        return .result(dialog: "\(message)")
    }
}

struct StopPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Phone Task"
    static let description = IntentDescription("Cancels pending voice tasks, stops the current run, and releases mouse buttons.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PhoneAgentViewModel.shared.stop()
        PhoneAgentViewModel.shared.notice = "Task stopped via Siri"
        PhoneAgentViewModel.shared.voiceRequestID = UUID()
        return .result(dialog: "Stopped the task and canceled pending requests.")
    }
}

struct PausePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Phone Task"
    static let description = IntentDescription("Cancels the old plan and releases input while keeping current task progress.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.pauseTask()
        return .result(dialog: "\(message)")
    }
}

struct HandoffPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Over Phone Task"
    static let description = IntentDescription("Pauses automation so you can handle it manually, then resume the original task later.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.pauseTask(handoff: true)
        return .result(dialog: "\(message)")
    }
}

struct ResumePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Phone Task"
    static let description = IntentDescription("Re-observes the screen using the original task and latest additions, then continues.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await PhoneAgentViewModel.shared.resumeVoiceTask()
        return .result(dialog: "\(message)")
    }
}

struct BeginTaskSupplementIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Current Task"
    static let description = IntentDescription("Pauses the current task, then opens dictation for additional instructions.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.beginVoice(.supplement)
        return .result(dialog: "\(message)")
    }
}

struct AmendPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task Instructions"
    static let description = IntentDescription("Receives dictation from a shortcut after pausing; waits for you to resume after adding.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Instructions", requestValueDialog: "What would you like to add?") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Add instructions \(\.$text)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.supplementTask(text)
        return .result(dialog: "\(message)")
    }
}

struct ListenPhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell the Assistant"
    static let description = IntentDescription("Opens Phone Agent's on-device dictation; edit the result and submit the task.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneAgentViewModel.shared
        let message = model.beginVoice(model.engine.hasCurrentTask ? .supplement : .task)
        return .result(dialog: "\(message)")
    }
}

// Available as parameterized actions in Shortcuts. Existing App Shortcut phrases
// remain stable; queue controls require the authenticated foreground app.
struct QueuePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Queue Phone Task"
    static let description = IntentDescription("Saves a new task without interrupting the current run; queued tasks run in order.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Task", requestValueDialog: "Which task should be queued?") var task: String
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$task) to the phone task queue") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestQueuedVoiceTask(task, priority: false)
        return .result(dialog: "\(message)")
    }
}
struct PrioritizePhoneTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Prioritize Phone Task"
    static let description = IntentDescription("Pauses the current task, runs the new task first, then resumes the original.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Task", requestValueDialog: "What should be done first?") var task: String
    static var parameterSummary: some ParameterSummary { Summary("Prioritize \(\.$task)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PhoneAgentViewModel.shared.requestQueuedVoiceTask(task, priority: true)
        return .result(dialog: "\(message)")
    }
}
struct RunPhoneQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Phone Task Queue"
    static let description = IntentDescription("Continues to the next item after confirmation; waits for any running task to finish.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = PhoneAgentViewModel.shared
        guard model.taskQueue.pendingCount > 0 else { return .result(dialog: "The queue has no pending tasks.") }
        model.runTaskQueue(); model.voiceRequestID = UUID()
        let message = model.queueStatus
        return .result(dialog: "\(message)")
    }
}

struct PhoneAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCurrentPhoneTaskIntent(), phrases: [
            "Start the current task with \(.applicationName)",
            "Run my phone task with \(.applicationName)",
            "Begin the current task in \(.applicationName)",
            "Get \(.applicationName) to work"
        ], shortTitle: "Start Task", systemImageName: "play.fill")
        AppShortcut(intent: RunPhoneTaskIntent(), phrases: [
            "Run a new task with \(.applicationName)",
            "Have \(.applicationName) run a phone task"
        ], shortTitle: "Run Task", systemImageName: "text.bubble")
        AppShortcut(intent: StopPhoneTaskIntent(), phrases: [
            "Stop the task in \(.applicationName)",
            "Stop \(.applicationName)",
            "Cancel the task in \(.applicationName)"
        ], shortTitle: "Stop Task", systemImageName: "stop.fill")
        AppShortcut(intent: PausePhoneTaskIntent(), phrases: ["Pause the task in \(.applicationName)", "Pause \(.applicationName)"], shortTitle: "Pause Task", systemImageName: "pause.fill")
        AppShortcut(intent: HandoffPhoneTaskIntent(), phrases: ["Take over the task in \(.applicationName)", "Let me take over \(.applicationName)"], shortTitle: "Take Over", systemImageName: "hand.raised.fill")
        AppShortcut(intent: ResumePhoneTaskIntent(), phrases: ["Resume the task in \(.applicationName)", "Continue the task in \(.applicationName)"], shortTitle: "Resume Task", systemImageName: "play.fill")
        AppShortcut(intent: BeginTaskSupplementIntent(), phrases: ["Add instructions in \(.applicationName)", "Add task requirements in \(.applicationName)"], shortTitle: "Add to Task", systemImageName: "text.badge.plus")
        AppShortcut(intent: AmendPhoneTaskIntent(), phrases: ["Update the task in \(.applicationName)", "Amend the task in \(.applicationName)"], shortTitle: "Add Instructions", systemImageName: "pencil")
        AppShortcut(intent: ListenPhoneTaskIntent(), phrases: ["Talk to \(.applicationName)", "Tell \(.applicationName) by voice"], shortTitle: "Tell Assistant", systemImageName: "mic.fill")
    }
}
