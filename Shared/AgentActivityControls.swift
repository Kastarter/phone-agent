import Foundation
import AppIntents
import ActivityKit

enum ActivityTaskControl: String { case pause, stop }

// Installed only by the live app model. Nothing restores this handler, an
// execution session or an engine from an activity / persisted queue record.
@MainActor
enum AgentActivityControls {
    static var handler: ((UUID, UUID, ActivityTaskControl) async -> Void)?

    static func run(taskID: String, sessionID: String, control: ActivityTaskControl) async {
        guard let task = UUID(uuidString: taskID), let session = UUID(uuidString: sessionID) else { return }
        if let handler { await handler(task, session, control); return }
        // A cold process with no engine cannot stop a previously running task.
        // Retire only the matching stale activity; never create or resume work.
        for activity in Activity<AgentActivityAttributes>.activities
            where activity.attributes.taskID == task && activity.content.state.controlSessionID == session {
            var state = activity.content.state
            state.status = "Task status is stale. Check in the app."
            state.updatedAt = Date(); state.controlSessionID = nil
            state.canPause = false; state.canStop = false
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
    }
}

struct PauseActivityPhoneTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Phone Task in Live Activity"
    static let description = IntentDescription("Pauses this card's current run, cancels the plan, and releases input.")
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false
    @Parameter(title: "Task ID") var taskID: String
    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(taskID: UUID, sessionID: UUID) { self.taskID = taskID.uuidString; self.sessionID = sessionID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        await AgentActivityControls.run(taskID: taskID, sessionID: sessionID, control: .pause)
        return .result()
    }
}

struct StopActivityPhoneTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Phone Task in Live Activity"
    static let description = IntentDescription("Ends this card's task and pauses the queue; waiting items are kept.")
    static let supportedModes: IntentModes = [.background]
    static let allowedExecutionTargets: IntentExecutionTargets = [.main]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false
    @Parameter(title: "Task ID") var taskID: String
    @Parameter(title: "Session ID") var sessionID: String
    init() {}
    init(taskID: UUID, sessionID: UUID) { self.taskID = taskID.uuidString; self.sessionID = sessionID.uuidString }
    @MainActor func perform() async throws -> some IntentResult {
        await AgentActivityControls.run(taskID: taskID, sessionID: sessionID, control: .stop)
        return .result()
    }
}
