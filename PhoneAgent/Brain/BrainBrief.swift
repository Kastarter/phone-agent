import Foundation

/// The task brief: one text-only model call at the start of a run, made while Phone Agent leaves, that turns the
/// request into what the actor needs: the intent, the app, the exact text to type (translated: "hi in Arabic" is
/// "مرحبا"), a real search query for research ("search that thing" resolved from the context), whether the user
/// wants information back, and what needs the user's OK. The run waits for it at most `timeout` from the start;
/// without it the actor works from the goal alone.
struct BrainBrief: Equatable {
    enum Deliverable: String { case action, answer }
    var intent = ""
    var app: String?
    var steps: [String] = []
    var text: [String] = []
    var query: String?
    var deliverable = Deliverable.action
    var doneWhen = ""
    var confirmBefore: [String] = []
    var ask: String?

    static let timeout = 4.0
    static let maxTokens = 700

    static var system: String {
        #"""
You brief an agent that operates an iPhone by tapping and typing. You do not see the screen.
Reply with ONE JSON object, nothing else:
{"intent": "<one sentence>", "app": "<app id from the list the task happens in (for the open chat: its app, which reopens on it), or null>",
 "steps": ["<2-6 short concrete steps on screen>"], "text": ["<exact new strings to type, in their final language and script; [] if none>"],
 "query": "<the best web search query for a search, question or research task, else null>",
 "deliverable": "answer" (the user wants information back: prices, weather, results, facts) or "action",
 "done_when": "<what the screen shows when finished>",
 "confirm_before": ["<irreversible actions needing the user's OK: send, post, buy, pay, delete>"],
 "ask": "<one short question, only if the request cannot be acted on even with the context; else null>"}
Rules: resolve "that thing", "it", "him", "this chat" from the context. Translate when asked: "hi in Arabic" -> "مرحبا".
A query is what a person types into Google, never the user's sentence ("search that thing" after asking about coffee
in Riyadh -> "best coffee shops in Riyadh"). Fact questions (weather, prices, news, scores) are research: app "safari",
deliverable "answer". Names keep their original script. confirm_before is [] when the user already confirmed
(e.g. "send it" after a typed message). Prefer a reasonable guess over asking.
Apps: \#(AppLauncher.catalog.map(\.id).joined(separator: ", "))
"""#
    }

    /// A plain "open X" goal is done by the fast path without any model call: no brief for it.
    static func needed(goal: String, previewOnly: Bool) -> Bool {
        previewOnly || FastPaths.opening(goal: goal)?.onlyOpen != true
    }

    /// The brief's user text: the time and language, where the phone is, the earlier requests and the request.
    static func prompt(goal: String, context: String, now: Date = Date(), locale: String = Locale.preferredLanguages.first ?? "en") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return "Now: \(f.string(from: now)) (\(TimeZone.current.identifier)); phone language \(locale)\n"
            + "Phone now: the Home Screen (the agent just left its own app; an app reopens on its last screen)\n\n"
            + (context.isEmpty ? "" : context + "\n\n") + "Request: \(goal)"
    }

    /// The reply's JSON object (code fences and chatter around it are ignored); nil when it carries nothing usable.
    static func parse(_ reply: String) -> BrainBrief? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let json = (try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8))) as? [String: Any] else { return nil }
        func one(_ key: String, _ n: Int = 300) -> String? {
            guard let s = (json[key] as? String).map({ clip($0, n) }), !s.isEmpty,
                  !["null", "none", "n/a"].contains(s.lowercased()) else { return nil }
            return s
        }
        func list(_ key: String, split: Bool = false) -> [String] {
            let raw = json[key] as? [Any] ?? (json[key] as? String).map {
                split ? $0.components(separatedBy: CharacterSet(charactersIn: ",\n")) : [$0]
            } ?? []
            return raw.compactMap { $0 as? String }
                .map { clip($0.replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression), 200) }
                .filter { !$0.isEmpty && $0.lowercased() != "null" }
        }
        var b = BrainBrief()
        b.intent = one("intent") ?? ""
        b.app = one("app", 40)
        // The brief only adds caution: steps that send, pay or delete are left to the actor's own confirmation rules.
        b.steps = Array(list("steps").filter { !risky($0) }.prefix(6))
        b.text = Array(list("text").prefix(4))
        b.query = one("query", 160)
        b.deliverable = (json["deliverable"] as? String)?.lowercased() == "answer" ? .answer : .action
        b.doneWhen = one("done_when").flatMap { risky($0) ? nil : $0 } ?? ""
        b.confirmBefore = list("confirm_before", split: true).map { $0.lowercased() }
        b.ask = one("ask", 200)
        let empty = b.intent.isEmpty && b.steps.isEmpty && b.text.isEmpty && b.query == nil && b.ask == nil
        return empty ? nil : b
    }

    /// An irreversible action (send, post, buy, pay, delete, call…), which only the user can confirm.
    static func risky(_ s: String) -> Bool {
        s.range(of: #"\b(send|sent|sends|post|publish|share|buy|pay|purchase|order|book|delete|remove|erase|call|submit|transfer|confirm)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The actor's "Brief" block.
    var block: String {
        var lines: [String] = []
        if !intent.isEmpty { lines.append("Intent: " + intent) }
        if !steps.isEmpty { lines.append("Steps:\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")) }
        if !text.isEmpty { lines.append("Type exactly: " + text.map { "\"\($0)\"" }.joined(separator: ", ")) }
        if let query { lines.append("Search query: \"\(query)\"") }
        if !doneWhen.isEmpty { lines.append("Done when: " + doneWhen) }
        if !confirmBefore.isEmpty {
            lines.append("Needs the user's OK first: \(confirmBefore.joined(separator: ", ")) (stop before it with done, saying what is ready)")
        }
        if deliverable == .answer {
            lines.append("The user wants an answer: read it from the screen, then done <the information itself in one or two sentences>")
        }
        return lines.joined(separator: "\n")
    }

    /// The step log line.
    var summary: String {
        [intent, query.map { "search \"\($0)\"" }, text.isEmpty ? nil : "type " + text.map { "\"\($0)\"" }.joined(separator: ", "),
         app.map { "app \($0)" }, deliverable == .answer ? "answer back" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The catalog app the brief names (id, name or alias). Wi-Fi and Bluetooth have no icon: their app is Settings.
    var target: LaunchTarget? {
        guard let app else { return nil }
        let key = FastPaths.fold(app)
        guard let hit = AppLauncher.catalog.first(where: { t in ([t.id, t.name] + t.aliases).contains { FastPaths.fold($0) == key } })
        else { return nil }
        return ["wifi", "bluetooth"].contains(hit.id) ? AppLauncher.target(id: "settings") : hit
    }

    /// One line, at most `n` characters.
    private static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }

    /// What the voice agent asks the user.
    static func question(_ ask: String) -> String {
        let q = clip(ask, 200)
        return q.hasSuffix("?") || q.hasSuffix("؟") ? q : q + "?"
    }

    /// The information a done reply carries, as the voice agent speaks it.
    static func answer(_ done: String) -> String {
        let s = clip(done.replacingOccurrences(of: #"^\s*answer\s*[:\-]\s*"#, with: "", options: [.regularExpression, .caseInsensitive]), 600)
        guard s.count > 400 else { return s }
        let cut = s.prefix(400)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }
}

extension BrainBrief {
    /// One text-only call, canceled at `timeout`. The note says why there is no brief.
    @MainActor static func fetch(_ llm: ChatModel, goal: String, context: String) async -> (brief: BrainBrief?, seconds: Double, note: String) {
        let started = brainNow(), prompt = prompt(goal: goal, context: context)
        let call = Task { @MainActor in
            try await llm.chat(system: system, text: prompt, image: nil, maxTokens: maxTokens, temperature: 0)
        }
        let timer = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); call.cancel() }
        defer { timer.cancel() }
        let reply = await withTaskCancellationHandler { try? await call.value } onCancel: { call.cancel() }
        let seconds = brainNow() - started
        guard let reply else { return (nil, seconds, seconds >= timeout - 0.05 ? "timed out" : "the call failed") }
        guard let brief = parse(reply.text) else { return (nil, seconds, "unreadable reply: \(reply.text.prefix(80))") }
        return (brief, seconds, llm.model)
    }
}
