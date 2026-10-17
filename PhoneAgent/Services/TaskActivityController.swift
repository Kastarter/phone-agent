import Foundation
import Combine
import ActivityKit
import UIKit

@MainActor
final class TaskActivityController: ObservableObject {
    @Published private(set) var error = ""
    private var activity: Activity<AgentActivityAttributes>?
    private var queue: Task<Void, Never>?
    init() {
        // A previous process cannot still own our engine. Do not leave a stale
        // activity implying that an interrupted task continues after relaunch.
        queue = Task { for old in Activity<AgentActivityAttributes>.activities { await old.end(nil, dismissalPolicy: .immediate) } }
    }
    func represents(_ taskID: UUID) -> Bool { activity?.attributes.taskID == taskID }
    func flush() async { await queue?.value }
    func update(record: PhoneTaskRecord?, phase: AgentPhase, step: Int, action: String?, enabled: Bool, sessionID: UUID, releasing: Bool, canPause: Bool, canStop: Bool) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.apply(record: record, phase: phase, step: step, action: action, enabled: enabled,
                             sessionID: sessionID, releasing: releasing, canPause: canPause, canStop: canStop)
        }
    }
    private func apply(record: PhoneTaskRecord?, phase: AgentPhase, step: Int, action: String?, enabled: Bool, sessionID: UUID, releasing: Bool, canPause: Bool, canStop: Bool) async {
        guard enabled, let record else {
            if let activity { await activity.end(nil, dismissalPolicy: .immediate); self.activity = nil }
            return
        }
        let final = [.completed, .failed, .stopped, .idle, .preview].contains(phase)
        // Only generic action/status is exposed, never the task goal, screenshots,
        // model reasoning, contact details or other private result contents.
        var status: String
        switch phase {
        case .preparing: status = "Preparing"
        case .observing: status = "Observing and planning"
        case .acting: status = action ?? "Running"
        case .awaitingApproval: status = "Return to the app to confirm"
        default: status = phase.outcome.label
        }
        if releasing { status = "\(phase.outcome.label), finishing and releasing input" }
        let state = AgentActivityAttributes.ContentState(status: String(status.prefix(80)), step: step, updatedAt: Date(),
            controlSessionID: final ? nil : sessionID, canPause: !final && canPause && !releasing, canStop: !final && canStop)
        let content = ActivityContent(state: state, staleDate: final && !releasing ? nil : Date().addingTimeInterval(60))
        if let activity, activity.attributes.taskID != record.id { await activity.end(nil, dismissalPolicy: .immediate); self.activity = nil }
        if final && !releasing {
            if let activity { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(300))); self.activity = nil }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { error = "Live Activities are not allowed. Check Phone Agent permissions in Settings"; return }
        if let activity { await activity.update(content); error = "" }
        else if !final && UIApplication.shared.applicationState == .active {
            do { activity = try Activity.request(attributes: AgentActivityAttributes(taskID: record.id), content: content, pushType: nil); error = "" }
            catch { self.error = "Live Activity could not start; you can still follow the task in the app" }
        }
    }
}
