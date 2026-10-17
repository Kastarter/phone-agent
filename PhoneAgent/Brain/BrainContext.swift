import Foundation

/// What earlier requests did, so a follow-up ("send it", "him", "this chat", "in Arabic") means what the user meant.
/// The view model keeps it while a call is on (a typed task inherits it for 2 minutes); the Fast agent puts it in
/// its prompts as "Context so far". Each new request still replaces the running task.
struct SessionContext: Equatable {
    struct Turn: Equatable {
        var id: UUID
        var request: String, outcome: String
        /// Where the phone was when the request ended, as the agent last saw it.
        var screen: String
        var at: Date
    }
    static let limit = 4
    static let typedWindow: TimeInterval = 120
    private(set) var turns: [Turn] = []

    /// A task ended (or was replaced). The same task ending again (resumed) updates its turn.
    mutating func note(id: UUID, request: String, outcome: String, screen: String = "", at: Date = Date()) {
        let request = Self.clip(request, 300)
        guard !request.isEmpty else { return }
        let turn = Turn(id: id, request: request, outcome: Self.clip(outcome, 240), screen: Self.clip(screen, 200), at: at)
        if let i = turns.firstIndex(where: { $0.id == id }) { turns[i] = turn } else { turns.append(turn) }
        turns = Array(turns.suffix(Self.limit))
    }

    mutating func clear() { turns = [] }

    /// What a new task inherits: everything during a call; otherwise only if the last task ended under 2 min ago.
    func inherited(inCall: Bool, now: Date = Date()) -> [Turn] {
        guard let last = turns.last else { return [] }
        return inCall || now.timeIntervalSince(last.at) <= Self.typedWindow ? turns : []
    }

    /// The prompt block, or "" with nothing to inherit.
    static func block(_ turns: [Turn]) -> String {
        guard !turns.isEmpty else { return "" }
        var lines = turns.enumerated().map { "\($0.offset + 1). \"\($0.element.request)\" -> \($0.element.outcome)" }
        if let screen = turns.last?.screen, !screen.isEmpty { lines.append("Last screen: \(screen)") }
        return "Context so far (earlier requests, oldest first):\n" + lines.joined(separator: "\n")
            + "\nThe goal may refer to these (him, her, this chat, it, send it): resolve it with them and the screen."
    }

    /// How a finished task reads in the context.
    static func outcome(_ outcome: TaskOutcome, _ summary: String) -> String {
        let s = clip(summary, 200)
        switch outcome {
        case .completed: return s.isEmpty ? "done" : "done: " + s
        case .needsUser: return "stopped, needs the user: " + s
        case .failed: return "failed: " + s
        case .paused: return "paused"
        default: return "stopped before finishing (replaced or canceled)"
        }
    }

    /// One line, at most `n` characters.
    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }
}
