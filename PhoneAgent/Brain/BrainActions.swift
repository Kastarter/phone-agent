// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import CoreGraphics

/// Parsing of the model's THINK / DO replies (parse_command, parse_actions, parse_plan).
enum BrainActions {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bookkeeping keys that are not part of the action itself.
    static let meta: Set<String> = ["t", "thought", "think_s", "act_s", "shot", "_shot", "changed", "timing", "verify"]

    /// Gestures whose result may be taken as given when the same reply ends with done (e.g. tap an app icon, then done).
    static let predictable: Set<String> = ["tap", "swipe", "home", "back", "wait"]

    /// A reply that acts and then says done in one go. Allowed after predictable gestures only: the last one is
    /// marked "verify" (the screen must change, else no done) and later lines are dropped. After typing or keys
    /// (a message, a form) the done line is dropped, so the actor looks at the result first.
    static func earlyDone(_ acts: [JObject]) -> [JObject] {
        guard let k = acts.firstIndex(where: { $0["action"]?.str == "done" }), k > 0 else { return acts }
        guard acts[..<k].allSatisfy({ predictable.contains($0["action"]?.str ?? "") }) else { return Array(acts[..<k]) }
        var out = Array(acts[...k])
        out[k - 1]["verify"] = .bool(true)
        return out
    }

    /// action name -> argument names; numeric arguments are 0-1000 screen coordinates
    static let actions: [String: [String]] = [
        "tap": ["x", "y"], "swipe": ["x1", "y1", "x2", "y2"], "circle": ["x", "y", "r"], "path": ["points"],
        "type": ["text"], "key": ["combo"], "done": ["answer"], "fail": ["reason"],
        "home": [], "back": [], "wait": [], "replan": [],
    ]
    static let textArgs: Set<String> = ["text", "combo", "answer", "reason"]

    /// One DO line, e.g. "tap 152 362" -> {"action": "tap", "x": 152, "y": 362}.
    static func parseCommand(_ line: String) throws -> JObject {
        let (head, rest) = partition(line.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = head.lowercased()
        guard let keys = actions[name] else { throw ParseError(message: "unknown action: \(line.prefix(100))") }
        if let first = keys.first, textArgs.contains(first) {
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return ["action": .str(name), first: .str(text)]
        }
        let numbers = matches(#"-?\d+(?:\.\d+)?"#, in: rest).compactMap { Double($0) }.map { Int($0) }
        if keys == ["points"] {
            guard numbers.count >= 4, numbers.count % 2 == 0 else {
                throw ParseError(message: "path needs 2+ x y pairs: \(line.prefix(100))")
            }
            let points = stride(from: 0, to: numbers.count, by: 2).prefix(20)
                .map { JValue.arr([.int(numbers[$0]), .int(numbers[$0 + 1])]) }
            return ["action": .str(name), "points": .arr(Array(points))]
        }
        guard numbers.count == keys.count else {
            throw ParseError(message: "\(name) needs \(keys.count) numbers: \(line.prefix(100))")
        }
        var action: JObject = ["action": .str(name)]
        for (k, n) in zip(keys, numbers) { action[k] = .int(n) }
        if name == "tap" && rest.lowercased().contains("precise") { action["precise"] = .bool(true) }
        return action
    }

    /// Parse a THINK / DO… reply; the thought goes on the first action. At most 6 actions.
    static func parseActions(_ text: String) throws -> [JObject] {
        let thought = firstGroup(#"^\s*THINK\s*[:：]\s*(.*?)\s*$"#, in: text, multiline: true)
        var acts = try allGroups(#"^\s*DO\s*[:：]\s*(.*?)\s*$"#, in: text).map(parseCommand).prefix(6).map { $0 }
        guard !acts.isEmpty else { throw ParseError(message: "no DO line in reply: \(text.prefix(200))") }
        acts[0] = JObject([("thought", .str(thought ?? ""))]).merging(acts[0])
        return acts
    }

    /// The plan text; an EN: part is kept when the reply has EN: / ZH: parts.
    static func parsePlan(_ text: String) -> String {
        let re = try! NSRegularExpression(pattern: #"EN\s*[:：](.*?)ZH\s*[:：](.*)"#,
                                          options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return trim(ns.substring(with: m.range(at: 1)))
        }
        return trim(text)
    }

    /// The action itself, without thoughts, timings and other bookkeeping.
    static func key(_ step: JObject) -> JObject { step.without(meta) }

    /// Screen points (fractions) the pointer passes through for one action.
    static func pointerPath(_ act: JObject) -> [CGPoint] {
        func n(_ k: String) -> Double { act[k]?.double ?? 0 }
        func f(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 1000, y: y / 1000) }
        switch act["action"]?.str {
        case "tap": return [f(n("x"), n("y"))]
        case "swipe": return [f(n("x1"), n("y1")), f(n("x2"), n("y2"))]
        case "path": return points(act).map { f($0.x, $0.y) }
        case "circle": return [f(n("x") + n("r"), n("y"))]
        case "home": return [CGPoint(x: 0.5, y: 0.995), CGPoint(x: 0.5, y: 0.6)]
        case "back": return [CGPoint(x: 0.005, y: 0.45), CGPoint(x: 0.6, y: 0.45)]
        default: return []
        }
    }

    /// The [[x, y], …] points of a path action, in 0-1000 units.
    static func points(_ act: JObject) -> [CGPoint] {
        guard case .arr(let items)? = act["points"] else { return [] }
        return items.compactMap {
            guard case .arr(let p) = $0, p.count == 2, let x = p[0].double, let y = p[1].double else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    /// Points around a circle; r is a fraction of the width, aspect = width / height.
    static func circle(_ x: Double, _ y: Double, _ r: Double, aspect: Double, n: Int = 24) -> [CGPoint] {
        (0...n).map { i in
            let a = 2 * Double.pi * Double(i) / Double(n)
            return CGPoint(x: x + r * cos(a), y: y + r * aspect * sin(a))
        }
    }

    // MARK: - helpers

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func partition(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private static func regex(_ p: String, multiline: Bool) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: multiline ? [.anchorsMatchLines, .caseInsensitive] : [])
    }

    private static func matches(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: false).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func firstGroup(_ p: String, in s: String, multiline: Bool) -> String? {
        let ns = s as NSString
        guard let m = regex(p, multiline: multiline).firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allGroups(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: true).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}
