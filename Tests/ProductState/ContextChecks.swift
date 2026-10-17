import Foundation

/// Call memory and prompt assembly for the Fast agent: what a follow-up inherits and how the prompts read it.
enum ContextChecks {
    static func run() -> Int {
        var checks = 0
        func expect(_ ok: Bool, _ name: String) { precondition(ok, name); checks += 1 }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var session = SessionContext()
        expect(SessionContext.block(session.inherited(inCall: true)).isEmpty, "No context before any request")

        let first = UUID()
        session.note(id: first, request: "type hi in Arabic to him", outcome: SessionContext.outcome(.completed, "Typed مرحبا in the\nWhatsApp chat with Abdullah Al Rafai; not sent yet"),
                     screen: "The chat with Abdullah Al Rafai is open; مرحبا is in the message field.", at: t0)
        let block = SessionContext.block(session.inherited(inCall: true, now: t0.addingTimeInterval(600)))
        expect(block.hasPrefix("Context so far"), "The block is headed Context so far")
        expect(block.contains("1. \"type hi in Arabic to him\" -> done: Typed مرحبا in the WhatsApp chat with Abdullah Al Rafai; not sent yet"),
               "A turn keeps the request verbatim, its outcome on one line, Arabic intact")
        expect(block.contains("Last screen: The chat with Abdullah Al Rafai is open"), "The last screen is carried")

        // The same task ending again updates its turn; old turns roll off after the limit.
        session.note(id: first, request: "type hi in Arabic to him", outcome: SessionContext.outcome(.failed, "No chat open"), at: t0)
        expect(session.turns.count == 1 && session.turns[0].outcome == "failed: No chat open", "A task's turn is updated in place")
        for n in 0..<5 { session.note(id: UUID(), request: "request \(n)", outcome: SessionContext.outcome(.stopped, ""), at: t0.addingTimeInterval(Double(n))) }
        expect(session.turns.count == SessionContext.limit && session.turns.first?.request == "request 1", "Only the last turns are kept")
        expect(session.turns.last?.outcome == "stopped before finishing (replaced or canceled)", "A replaced task reads as stopped")
        session.note(id: UUID(), request: "  \n ", outcome: "done", at: t0)
        expect(session.turns.last?.request == "request 4", "Empty requests are ignored")

        // Typed tasks inherit only within two minutes; a call inherits everything.
        let last = t0.addingTimeInterval(4)
        expect(!session.inherited(inCall: false, now: last.addingTimeInterval(119)).isEmpty, "Typed task within 2 min inherits")
        expect(session.inherited(inCall: false, now: last.addingTimeInterval(121)).isEmpty, "Typed task after 2 min starts fresh")
        expect(session.inherited(inCall: true, now: last.addingTimeInterval(3600)).count == SessionContext.limit, "A call keeps its context")
        expect(SessionContext.clip(String(repeating: "a", count: 500), 300).count == 300, "Long text is clipped")
        session.clear()
        expect(session.turns.isEmpty, "A new call starts empty")

        // Prompt assembly: context first, then goal, plan and history.
        let bare = BrainPrompts.actorPrompt(goal: "Open WhatsApp", context: "", plan: "", history: [])
        expect(bare.hasPrefix("Goal: Open WhatsApp\n\nPlan:\n(none: act straight") && bare.hasSuffix("Recent actions:\n(none)\n\nNext action?"),
               "Without context the actor prompt is unchanged")
        let withContext = BrainPrompts.actorPrompt(goal: "send it", context: block, plan: "1. Tap Send", history: ["{\"action\": \"tap\"} -> screen changed"])
        expect(withContext.hasPrefix(block + "\n\nGoal: send it\n\nPlan:\n1. Tap Send\n\nRecent actions:\n{\"action\": \"tap\"} -> screen changed"),
               "The context block leads the actor prompt")
        expect(BrainPrompts.plannerPrompt(goal: "send it", context: block, stuck: nil) == block + "\n\nGoal: send it", "Planner prompt with context")
        let briefed = BrainPrompts.actorPrompt(goal: "type hi to him in Arabic", context: block, plan: "", history: [], brief: "Type exactly: \"مرحبا\"")
        expect(briefed.hasPrefix(block + "\n\nGoal: type hi to him in Arabic\n\nBrief:\nType exactly: \"مرحبا\"\n\nRecent actions:\n(none)"),
               "Context, goal, then the brief in place of the plan placeholder")
        expect(BrainPrompts.plannerPrompt(goal: "g", context: "", stuck: "stuck") == "Goal: g\n\nstuck", "Planner prompt when stuck")

        // The rules the call findings asked for, and the prompt stays short.
        let actor = BrainPrompts.actor
        expect(actor.contains("never search for another name") && actor.contains("say \"send\" to send it"), "Open-chat and confirm-before-send rules")
        expect(actor.contains("keyboard check learned") && actor.contains("original script") && actor.contains("never cmd+h"), "Typing by learned keyboards; no Cmd+H")
        expect(!actor.lowercased().contains("paste") && !actor.lowercased().contains("arabic keyboard"), "No paste or keyboard-switching advice: the device switches sources")
        expect(BrainPrompts.actorBase.count < 3800, "The actor prompt stays short (\(BrainPrompts.actorBase.count) chars)")
        return checks
    }
}
