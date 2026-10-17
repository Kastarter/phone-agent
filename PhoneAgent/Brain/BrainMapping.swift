import Foundation
import CoreGraphics

// Maps the fast agent's actions onto the app's AgentAction, so logs, approvals, Live Activity and PiP read them.
extension BrainActions {
    /// The action as the app's UI, approvals and records show it (coordinates ÷ 1000; replan has no mapping).
    static func agentAction(_ act: JObject) -> AgentAction {
        func p(_ k: String) -> Double { min(1, max(0, (act[k]?.double ?? 0) / 1000)) }
        let thought = act["thought"]?.str ?? ""
        let timing = act["timing"]?.str ?? ""
        let base = thought.isEmpty ? "Next step of the plan" : thought
        let reason = base + (timing.isEmpty ? "" : " · " + timing)
        switch act["action"]?.str {
        case "tap": return AgentAction(kind: .tap, x: p("x"), y: p("y"), reason: reason)
        case "swipe": return AgentAction(kind: .drag, x: p("x1"), y: p("y1"), x2: p("x2"), y2: p("y2"), reason: reason)
        case "path":
            let pts = BrainActions.points(act)
            func c(_ v: CGFloat) -> Double { min(1, max(0, Double(v) / 1000)) }
            return AgentAction(kind: .drag, x: c(pts.first?.x ?? 0), y: c(pts.first?.y ?? 0),
                               x2: c(pts.last?.x ?? 0), y2: c(pts.last?.y ?? 0), reason: reason)
        case "circle":
            let x = min(1, max(0, ((act["x"]?.double ?? 0) + (act["r"]?.double ?? 0)) / 1000))
            return AgentAction(kind: .drag, x: x, y: p("y"), x2: x, y2: p("y"), reason: reason)
        case "type": return AgentAction(kind: .type, text: act["text"]?.str ?? "", reason: reason)
        case "key": return AgentAction(kind: .press_key, text: act["combo"]?.str ?? "", reason: reason)
        case "home": return AgentAction(kind: .press_key, text: "home", reason: reason)
        case "back": return AgentAction(kind: .drag, x: 0.005, y: 0.45, x2: 0.6, y2: 0.45, reason: reason)
        // The answer goes back to the user (and the voice call) as is, without timings.
        case "done": return AgentAction(kind: .finish, reason: act["answer"]?.str ?? base)
        case "fail": return AgentAction(kind: .ask_user, reason: act["reason"]?.str ?? base)
        default: return AgentAction(kind: .wait, seconds: 1, reason: reason)
        }
    }
}
