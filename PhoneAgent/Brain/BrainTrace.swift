import Foundation

/// Phase timings of fast-agent runs, so speed can be measured on the device: one line per phase in
/// Documents/fast-agent-trace.log (kept under ~200 KB), and a short per-step summary for the step log.
@MainActor enum BrainTrace {
    static let cap = 200_000
    private static var pending: [(String, Double)] = []
    private static var file: URL? {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("fast-agent-trace.log")
        #else
        nil  // the offline checks on a Mac write no trace
        #endif
    }

    /// A new run: a header line, and no summary carried over from the last run.
    static func begin(_ goal: String) {
        pending = []
        write("--- \(ISO8601DateFormatter().string(from: Date())) run: \(goal.prefix(120))")
    }

    /// One phase took `seconds`; `note` says what it was (e.g. the action). step: false logs it only (run totals).
    static func mark(_ phase: String, _ seconds: Double, _ note: String = "", step: Bool = true) {
        if step { pending.append((phase, seconds)) }
        write("\(phase) \(Int((seconds * 1000).rounded())) ms\(note.isEmpty ? "" : " " + note)")
    }

    /// Time `body` as `phase`.
    static func time<T>(_ phase: String, _ note: String = "", _ body: () async throws -> T) async rethrows -> T {
        let started = brainNow()
        defer { mark(phase, brainNow() - started, note) }
        return try await body()
    }

    /// The phases since the last summary, e.g. "model 1.4 s, move 0.6 s"; clears them.
    static func summary() -> String {
        defer { pending = [] }
        return format(pending)
    }

    /// Sums repeated phases, keeps first-seen order, drops phases under 50 ms. The actor/planner calls read "model".
    nonisolated static func format(_ phases: [(String, Double)]) -> String {
        var order: [String] = [], sums: [String: Double] = [:]
        for (phase, s) in phases {
            let name = phase == "actor" || phase == "plan" ? "model" : phase
            if sums[name] == nil { order.append(name) }
            sums[name, default: 0] += s
        }
        return order.filter { sums[$0]! >= 0.05 }.map { "\($0) \(String(format: "%.1f", sums[$0]!)) s" }.joined(separator: ", ")
    }

    private static func write(_ line: String) {
        guard let file else { return }
        let data = Data((line + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else { try? data.write(to: file); return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(cap) {  // keep the newer half
            try? handle.close()
            let old = (try? Data(contentsOf: file)) ?? Data()
            try? (old.suffix(cap / 2) + data).write(to: file)
            return
        }
        try? handle.write(contentsOf: data)
    }
}
