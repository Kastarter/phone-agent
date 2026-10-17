// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import CoreGraphics

/// See-think-act brain: an actor model picks up to six actions per look, straight from the goal; a planner model
/// writes a plan only when the actor gets stuck or asks for one (replan). AgentEngine owns the loop; this class
/// owns the prompts, history and gestures.
@MainActor final class FastAgent {
    let phone: Gestures
    let screen: ScreenSource
    let actor: ChatModel, planner: ChatModel
    static let maxTokens = ["planner": 3072, "actor": 2048]

    /// Awaited before every look and every gesture (the app holds the run while its own UI is in front).
    var gate: (() async throws -> Void)?
    private(set) var task = ""
    private(set) var plan = ""
    private(set) var steps: [JObject] = []
    /// When the last gesture ended: the model never decides on a frame from before it.
    private(set) var lastActed = 0.0
    /// The screenshot the last actor reply was decided on; every action of one reply refers to it.
    private(set) var shot: Data?
    /// Last pointer position (screen fractions): pointer moves are not screen changes.
    private(set) var pointerAt = CGPoint.zero
    /// When the run started (before leaving the app), and the pointer spots of the current reply's gestures.
    private var startedAt = 0.0
    private var batchSpots: [CGPoint] = []
    /// Earlier requests of this conversation ("Context so far"), fixed for the run.
    private(set) var context = ""
    /// The task brief (BrainBrief), once it arrived; the prompts carry it as "Brief".
    var brief: BrainBrief?
    /// The first actor call, started on the first frame after leaving the app while the screen still settles.
    private var early: (frame: Data, started: Double, reply: Task<ChatResult, Error>)?

    /// The context a new run inherits (the view model's session); read once when a run starts.
    static var sessionContext: () -> String = { "" }
    /// The last thought of the latest run: where the phone was when it ended, for the next request's context.
    private(set) static var lastLook = ""

    init(phone: Gestures, screen: ScreenSource, actor: ChatModel, planner: ChatModel) {
        self.phone = phone; self.screen = screen; self.actor = actor; self.planner = planner
    }

    func start(goal: String, context: String? = nil) {
        task = goal; plan = ""; steps = []; lastActed = 0; shot = nil; pointerAt = .zero; startedAt = brainNow()
        self.context = context ?? Self.sessionContext(); brief = nil; early?.reply.cancel(); early = nil; Self.lastLook = ""
        BrainTrace.begin(goal)
    }

    /// After leaving the app: the first frame of what is in front now (or the capture confirming the shown one is
    /// current) starts the first actor call, while the screen settles. nextActions uses that reply only if the
    /// settled screen still looks the same; otherwise it asks again on the settled frame.
    func arrive(since: Double) async {
        let deadline = brainNow() + 3
        while screen.capturedAt <= since && !screen.idle(since: since) && brainNow() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lookAhead()
        let started = brainNow()
        await screen.settled()
        BrainTrace.mark("settle", brainNow() - started, "first look")
    }

    func lookAhead() {
        guard steps.isEmpty, early == nil, screen.live, let frame = screen.frame else { return }
        let llm = actor, prompt = actorPrompt(), tokens = Self.maxTokens["actor"] ?? 2048
        early = (frame, brainNow(), Task { @MainActor in
            try await llm.chat(system: BrainPrompts.actor, text: prompt, image: frame, maxTokens: tokens, temperature: 0)
        })
    }

    /// The look-ahead reply, decided on a frame the settled screen still matches; nil to ask afresh.
    private func takeEarly() async throws -> (String, Double, Data?)? {
        guard let ahead = early else { return nil }
        let (seen, started, reply) = ahead
        early = nil
        guard steps.isEmpty else { reply.cancel(); return nil }
        try await gate?()
        guard screen.live else { reply.cancel(); return nil }
        let result = try? await withTaskCancellationHandler { try await reply.value } onCancel: { reply.cancel() }
        try Task.checkCancellation()
        guard let result else { return nil }
        let waited = brainNow() - started
        guard let latest = screen.frame, !Self.bigChange(seen, latest) else {
            BrainTrace.mark("actor", waited, "\(actor.model) look-ahead discarded: the screen changed", step: false)
            return nil
        }
        BrainTrace.mark("actor", waited, "\(actor.model) look-ahead")
        return (result.text, (waited * 100).rounded() / 100, latest)
    }

    /// A different screen (not a pointer, clock or badge): the mean gray difference on a 32x64 thumbnail.
    static func bigChange(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return true }
        if a == b { return false }
        guard let ia = FrameVision.image(a), let ib = FrameVision.image(b), ia.width == ib.width, ia.height == ib.height else { return true }
        let ga = FrameVision.gray(ia, 32, 64), gb = FrameVision.gray(ib, 32, 64)
        let total = zip(ga.px, gb.px).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(ga.px.count) > 1.0
    }

    /// Bookkeeping for the next prompt: the action and whether the screen changed after it.
    func record(_ act: JObject, changed: Bool?) {
        var step = JObject([("t", .num(brainNow()))]).merging(act)
        if let changed { step["changed"] = .bool(changed) }
        if act["action"]?.str == "type", let check = phone.device.typeCheck { step["check"] = .str(check) }
        steps.append(step)
    }

    private func ask(_ role: String, _ llm: ChatModel, _ system: String, _ prompt: String,
                     temperature: Double = 0, retryTimeout: Bool = true) async throws -> (String, Double, Data?) {
        try await gate?()
        guard screen.live, let frame = screen.frame else {  // never let the model act blind
            throw DeviceError(message: "No full-screen frame; share the full screen again")
        }
        let started = brainNow()
        do {
            let reply = try await llm.chat(system: system, text: prompt, image: frame,
                                           maxTokens: Self.maxTokens[role] ?? 2048, temperature: temperature)
            BrainTrace.mark(role == "planner" ? "plan" : "actor", brainNow() - started, llm.model)
            return (reply.text, ((brainNow() - started) * 100).rounded() / 100, frame)
        } catch {
            guard retryTimeout, BrainLLM.isTimeout(error), !Task.isCancelled else { throw error }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            // Re-enter the gate and screen checks before retrying; no gesture is repeated.
            return try await ask(role, llm, system, prompt, temperature: temperature, retryTimeout: false)
        }
    }

    /// The previous round changed nothing on screen, so a tap may have landed off target.
    private var missed: Bool { steps.last?["changed"] == .bool(false) }

    /// True when the actor picks the same action as its last limit-1 moves and the last one did nothing.
    /// Repeating a move that still changes the screen (e.g. scrolling down a long list) is progress, not a loop.
    func repeating(_ act: JObject) -> Bool {
        let limit = 3
        let moves = steps.filter { $0["plan"] == nil }.suffix(limit - 1)
        return moves.count == limit - 1 && moves.allSatisfy { BrainActions.key($0) == BrainActions.key(act) }
            && moves.last?["changed"] != .bool(true)
    }

    /// The first call (stuck: false) asks no model: the actor starts from the goal, which saves a whole model
    /// round before the first gesture. The planner runs when the actor is stuck or replies replan.
    @discardableResult func replan(stuck: Bool) async throws -> String {
        guard stuck || !steps.isEmpty else {
            BrainTrace.mark("leave", brainNow() - startedAt)
            return "Acting straight toward the goal; a plan is made only if needed"
        }
        var note: String?
        if stuck || !plan.isEmpty {
            let last = steps.last ?? JObject()
            note = "The previous plan got stuck (last event: \(pyStr(last["action"])) \(last["reason"]?.str ?? "")):"
                + "\n\(plan.isEmpty ? "(no written plan yet)" : plan)\nLook at the current screen and plan from here, another way if needed."
        }
        let prompt = BrainPrompts.plannerPrompt(goal: task, context: context, stuck: note, brief: brief?.block ?? "")
        let (reply, seconds, _) = try await ask("planner", planner, BrainPrompts.planner, prompt)
        plan = BrainActions.parsePlan(reply)
        steps.append(["action": .str(stuck ? "replan (stuck)" : "plan"), "plan": .str(plan), "think_s": .num(seconds)])
        return plan
    }

    /// The actor's prompt for the next look. History: actions and their effect only; echoing earlier thoughts makes
    /// the model repeat them instead of looking.
    func actorPrompt() -> String {
        let hidden: Set<String> = ["t", "plan", "think_s", "act_s", "shot", "thought", "changed", "timing", "verify"]
        let history = steps.suffix(8).filter { $0["plan"] == nil }.map { s -> String in
            let effect = s["changed"] == .bool(true) ? " -> screen changed"
                : s["changed"] == .bool(false) ? " -> screen did NOT change" : ""
            return String(PyJSON.dumps(s.without(hidden)).prefix(300)) + effect
        }
        return BrainPrompts.actorPrompt(goal: task, context: context, plan: plan, history: history, brief: brief?.block ?? "")
    }

    /// One actor call: up to six parsed DO actions, the thought on the first.
    func nextActions() async throws -> [JObject] {
        var prompt = actorPrompt()
        var reply = ""
        for attempt in 0..<3 {  // retry unparseable replies, a little less deterministically
            var got: (String, Double, Data?)
            if let ahead = try await takeEarly() { got = ahead }
            else { got = try await ask("actor", actor, BrainPrompts.actor, prompt, temperature: 0.4 * Double(attempt)) }
            let (text, seconds, frame) = got
            reply = text
            guard var acts = (try? BrainActions.parseActions(text)).map(BrainActions.earlyDone), !acts.isEmpty else { continue }
            if missed, let last = steps.last, BrainActions.key(acts[0]) == BrainActions.key(last) {  // same move that did nothing
                prompt += "\n\nYou just proposed \(PyJSON.dumps(BrainActions.key(acts[0]))) again, but it changed nothing last "
                    + "time. Choose a different action (another position, a shorter swipe, or another way)."
                continue
            }
            acts[0]["think_s"] = .num(seconds)
            if let thought = acts[0]["thought"]?.str, !thought.isEmpty { Self.lastLook = thought }
            let timing = BrainTrace.summary()
            if !timing.isEmpty { acts[0]["timing"] = .str(timing) }
            if acts.contains(where: { $0["action"]?.str == "done" }) {
                BrainTrace.mark("done", brainNow() - startedAt, "run total, \(acts.count) action(s) in the last reply", step: false)
            }
            shot = frame; batchSpots = [pointerAt]
            return acts
        }
        throw BrainActions.ParseError(message: "The model gave no valid action: \(reply.prefix(200))")
    }

    /// The gate, then the gesture. Coordinates are 0-1000 screen units.
    func perform(_ a: JObject) async throws {
        try await gate?()
        func p(_ k: String) -> Double { (a[k]?.double ?? 0) / 1000 }
        switch a["action"]?.str {
        case "tap": try await phone.tap(p("x"), p("y"), aim: a["precise"]?.bool ?? false || missed)
        case "swipe": try await phone.swipe(p("x1"), p("y1"), p("x2"), p("y2"), hold: true)
        case "path": try await phone.drag(BrainActions.points(a).map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }, hold: true)
        case "circle": try await phone.drag(BrainActions.circle(p("x"), p("y"), p("r"), aspect: screen.aspect), hold: true)
        case "type": try await phone.type(a["text"]?.str ?? "")  // the device traces kbd detect/switch, type, type verify
        case "key": try await BrainTrace.time("key") { try await phone.key(a["combo"]?.str ?? "") }
        case "home": try await phone.goHome()
        case "back": try await phone.goBack()
        case "wait": try await Task.sleep(nanoseconds: 1_000_000_000)
        case let other: throw BrainActions.ParseError(message: "unknown action \(other ?? "nil")")
        }
        lastActed = brainNow()
        pointerAt = BrainActions.pointerPath(a).last ?? pointerAt
        batchSpots += BrainActions.pointerPath(a)
        // The reply already said done after this gesture: only a screen change lets that done stand.
        if a["verify"] == .bool(true), !(await settleChanged(seen: shot, spots: batchSpots)) {
            record(a, changed: false)
            throw DeviceError(message: "The screen did not change after \(a["action"]?.str ?? "the action"), so it is not done yet; looking again")
        }
    }

    /// Wait for the screen to show the result, then compare it with what the model saw.
    func settleChanged(seen: Data?, spots: [CGPoint]) async -> Bool {
        let started = brainNow()
        await screen.afterAction(since: lastActed)
        let changed = FrameVision.changed(seen, screen.frame, ignore: spots)
        BrainTrace.mark("settle", brainNow() - started, changed ? "changed" : "unchanged")
        return changed
    }

    /// The action as the app's UI, approvals and records show it.
    static func agentAction(_ act: JObject) -> AgentAction { BrainActions.agentAction(act) }

    /// Python's str() of a value in an f-string (None for a missing key).
    private func pyStr(_ v: JValue?) -> String {
        guard let v else { return "None" }
        if case .str(let s) = v { return s }
        return PyJSON.dumps(v)
    }
}
