import Foundation
import Combine
import UIKit

enum AgentPhase: String {
    case idle, preparing, observing, acting, awaitingApproval, paused, needsUser, completed, failed, stopped, preview
    var outcome: TaskOutcome {
        switch self {
        case .paused: return .paused
        case .needsUser: return .needsUser
        case .completed: return .completed
        case .failed: return .failed
        case .stopped, .idle: return .stopped
        case .preview: return .preview
        default: return .running
        }
    }
}

@MainActor
final class AgentEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase: AgentPhase = .idle
    @Published private(set) var releasing = false
    @Published private(set) var currentRecord: PhoneTaskRecord?
    var onRecord: ((PhoneTaskRecord) -> Void)?
    private var savedGoal = ""
    private var savedSettings: AgentSettings?
    private var releaseTask: Task<Void, Never>?
    /// What a call speaks back verbatim instead of the usual "Done. …": the brief's clarifying question, or the
    /// information the user asked for (BrainBrief).
    private(set) var spokenResult: String?
    var canResume: Bool { savedSettings != nil && [.paused, .needsUser, .failed].contains(phase) && !releasing }
    var executionSettled: Bool { !running && !releasing && loop == nil }
    var currentSettings: AgentSettings? { savedSettings }
    var hasCurrentTask: Bool { savedSettings != nil && currentRecord != nil }
    private func transition(_ phase: AgentPhase, _ message: String) {
        self.phase = phase; state = message; publishRecord()
    }
    private func publishRecord() {
        guard var record = currentRecord else { return }
        record.updatedAt = Date(); record.outcome = phase.outcome; record.summary = state; record.logs = logs
        currentRecord = record; onRecord?(record)
    }
    func renameCurrent(_ title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        currentRecord?.title = String(title.prefix(80)); publishRecord()
    }
    func discardCurrent() {
        guard !running, !releasing else { return }
        currentRecord = nil; savedSettings = nil; logs = []; phase = .idle; state = "Ready to start"; error = ""
    }
    @Published private(set) var taskIndicator: MouseProtocol.TaskIndicator = .idle
    @Published private(set) var state = "Ready to start"
    @Published private(set) var logs: [AgentLogEntry] = []
    @Published private(set) var pendingAction: AgentAction?
    @Published private(set) var executingAction: AgentAction?
    @Published private(set) var error = ""
    @Published private(set) var currentStep = 0
    private var loop: Task<Void, Never>?
    private var session = UUID()
    var activityControlSessionID: UUID { session }
    private var approved = false
    let capture: CaptureService
    let executor: MouseExecutor
    private var launchedAt = 0.0
    // The fast agent's adapters, kept across runs so the pointer's learned correction survives.
    private lazy var brainScreen = BrainScreen(capture: capture)
    private lazy var brainDevice = BrainDevice(executor: executor)
    private lazy var brainPointer: BrainPointer = {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pointer = BrainPointer(device: brainDevice, calibrationFile: folder.appendingPathComponent("brain-pointer.json"), screen: brainScreen)
        // Typing reads the on-screen keyboard and taps its 🌐 key to switch input sources.
        brainDevice.screen = brainScreen
        brainDevice.tapAt = { [weak pointer] x, y in try await pointer?.tap(x, y, aim: false) }
        return pointer
    }()

    init(capture: CaptureService, executor: MouseExecutor) { self.capture = capture; self.executor = executor }
    func log(_ title: String, _ detail: String, step: Int? = nil) {
        logs.append(AgentLogEntry(step: step ?? currentStep, title: title, detail: detail))
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
        publishRecord()
    }
    func clearLogs() { if !running { logs = []; publishRecord() } }
    func approve() { approved = true }
    private func cancelAndRelease() {
        session = UUID(); let previous = loop; previous?.cancel(); loop = nil
        running = false; pendingAction = nil; executingAction = nil
        guard releaseTask == nil else { return }
        releasing = true
        releaseTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.executor.ble.release()
            self.releasing = false; self.releaseTask = nil
        }
    }
    func pause() {
        guard running else { return }
        cancelAndRelease(); taskIndicator = .idle
        transition(.paused, "Paused. When you resume, check the latest screen first.")
        log("Paused", "Canceled the old plan and released input; the last step may have partly run, so check the result before resuming.")
    }
    func handoff() {
        guard hasCurrentTask else { return }
        cancelAndRelease(); taskIndicator = .idle; error = ""
        transition(.needsUser, "Handed over to you. When you're done, say \"resume\".")
        log("You took over", "Kept the task and progress, canceled the old plan, and released input. The current screen is re-checked when you resume.")
    }
    func amendTask(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasCurrentTask, var record = currentRecord else { throw AgentError.message("There's no current task to add to; start a task first") }
        guard !text.isEmpty, text.count <= 4000 else { throw AgentError.message("The addition must be 1–4,000 characters") }
        guard (record.amendments ?? []).count < 20 else { throw AgentError.message("This task has already received 20 additions; organize your requirements and create a new task") }
        record.amendments = (record.amendments ?? []) + [TaskAmendment(text: text)]
        guard record.effectiveGoal.count <= 12000 else { throw AgentError.message("The task plus its additions are too long; organize your requirements and create a new task") }
        cancelAndRelease(); taskIndicator = .idle; error = ""
        currentRecord = record; savedGoal = record.effectiveGoal
        transition(.paused, "Addition added. Say \"resume\" to continue with the new requirements.")
        log("Addition", text)
    }
    func stop(reason: String = "Stopped") {
        let active = running || canResume
        cancelAndRelease()
        // A finished task keeps its outcome: Stop after "Done" (e.g. a call's stop tool) must not rewrite it as stopped.
        if reason == "Stopped" { error = ""; taskIndicator = .idle; if active || savedSettings != nil { transition(.stopped, reason) }; savedSettings = nil }
        else if active {
            error = reason; taskIndicator = .failed; transition(.failed, reason)
        }
    }
    private func checkReady(_ settings: AgentSettings) throws {
        guard PrivacyConsent.allowed(settings) else { throw AgentError.message("Confirm sending screen and task data to the current AI service first") }
        guard !settings.usesBedrock else { throw AgentError.message("The phone agent needs an OpenAI-compatible endpoint; Bedrock works for chat only") }
        _ = try ModelEndpointPolicy.url(settings.endpoint)
        guard capture.running, capture.frame?.fullDisplay == true else { throw AgentError.message("Start full-screen sharing through the system picker first") }
        if !settings.previewOnly {
            _ = try executor.validateCalibration(frame: capture.frame)
            guard executor.ble.ready else { throw AgentError.message("Connect the Bluetooth mouse first") }
        }
        guard !SettingsStore.apiKey(for: settings.endpoint).isEmpty else { throw AgentError.message("Save the API key in Settings") }
    }
    func start(task: String, settings: AgentSettings) {
        guard !running, !releasing else { return }
        let goal = task.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !goal.isEmpty, goal.count <= 12000 else { throw AgentError.message("Enter a task of 1–12,000 characters") }
            try checkReady(settings)
        } catch { self.error = error.localizedDescription; return }
        if currentRecord != nil, savedSettings != nil {
            transition(.stopped, "Switched to a new task")
        }
        savedGoal = goal; savedSettings = settings
        error = ""; pendingAction = nil; executingAction = nil; logs = []; currentStep = 0
        currentRecord = PhoneTaskRecord(title: String(goal.prefix(36)), goal: goal)
        launch(goal: goal, settings: settings, resumed: false)
    }
    // Queue restores preserve the same task ID and amendments. Pending actions are deliberately not part of
    // the checkpoint.
    func restoreQueued(record: PhoneTaskRecord, settings: AgentSettings, step: Int, previouslyStarted: Bool) throws {
        guard executionSettled else { throw AgentError.message("Finishing the previous run; please try again shortly") }
        guard !record.effectiveGoal.isEmpty, record.effectiveGoal.count <= 12000,
              (0...100).contains(step), step < settings.maxSteps,
              ![TaskOutcome.completed, .stopped, .preview].contains(record.outcome) else {
            throw AgentError.message("This queued task can't continue; check the result or create a new task")
        }
        try checkReady(settings)
        savedGoal = record.effectiveGoal; savedSettings = settings
        currentRecord = record; logs = record.logs; currentStep = step
        approved = false
        if previouslyStarted { log("Continuing from queue", "Kept the task ID; the last step may have partly run, so check the current state first and don't replay old actions.") }
        launch(goal: savedGoal, settings: settings, resumed: previouslyStarted)
        guard running else { throw AgentError.message("The queue record couldn't be saved and execution didn't start") }
    }
    func configurePausedTask(settings: AgentSettings) {
        guard canResume else { return }
        savedSettings = settings
    }
    func resume(settings: AgentSettings? = nil, delay: Double? = nil) {
        guard canResume, let previousSettings = savedSettings else { return }
        let savedSettings = settings ?? previousSettings
        do {
            try checkReady(savedSettings)
            guard currentStep < savedSettings.maxSteps else { throw AgentError.message("Reached the action-step limit; check the task result and create a new task") }
        } catch { self.error = error.localizedDescription; return }
        self.savedSettings = savedSettings
        log("Resume task", "The last action may have partly run; check the current page, fields, and sent results first, and don't replay old actions.")
        launch(goal: savedGoal, settings: savedSettings, resumed: true, resumeDelay: delay)
    }
    private func launch(goal: String, settings: AgentSettings, resumed: Bool, resumeDelay: Double? = nil) {
        error = ""; pendingAction = nil; executingAction = nil; spokenResult = nil
        let token = UUID(); session = token
        running = true; taskIndicator = .running; transition(.preparing, resumed ? "Resuming the task" : "Preparing the task")
        guard running else { return } // Record persistence may synchronously pause a queue.
        var runSettings = settings
        if resumed { runSettings.startDelay = min(30, max(2, resumeDelay ?? min(3, settings.startDelay))) }
        let firstStep = currentStep + 1
        launchedAt = Date().timeIntervalSince1970
        _ = brainScreen  // start tracking frames before the run looks
        loop = Task { [weak self] in await self?.runFast(goal: goal, settings: runSettings, token: token, firstStep: firstStep) }
    }
    private func stillCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == session && running else { throw CancellationError() }
    }
    /// The Fast agent: up to six actions per look, a plan only when stuck, Home Screen labels or search to open
    /// apps. The engine owns phases, logs, approvals, the step limit and cleanup.
    private func runFast(goal: String, settings: AgentSettings, token: UUID, firstStep: Int) async {
        let pointer = brainPointer, screen = brainScreen
        let llm = BrainLLM(settings: settings, apiKey: SettingsStore.apiKey(for: settings.endpoint))
        let agent = FastAgent(phone: pointer, screen: screen, actor: llm, planner: llm)
        let resumedAt = launchedAt, previewOnly = settings.previewOnly
        agent.gate = { [weak self, weak agent] in
            guard let self else { throw CancellationError() }
            try self.stillCurrent(token)
            if !previewOnly {
                try await holdWhileInFront(pointer: pointer, lastActed: agent?.lastActed ?? 0, running: self.running,
                                           capture: screen, resumedAt: resumedAt) {
                    self.transition(self.phase, "Paused while Phone Agent is in front; go to the Home Screen to continue")
                }
                try self.stillCurrent(token)
            }
        }
        do {
            pointer.beginRun()
            if !previewOnly { pointer.adopt(try executor.validateCalibration(frame: capture.frame)) }
            agent.start(goal: goal)
            // The task brief runs while Phone Agent leaves (and the app opens); the first look waits for it at most
            // until BrainBrief.timeout after the start. A plain "open X" needs none: it stays without a model call.
            let context = agent.context, direct = previewOnly ? nil : FastPaths.opening(goal: goal)
            let briefing = !BrainBrief.needed(goal: goal, previewOnly: previewOnly) ? nil
                : Task { @MainActor in await BrainBrief.fetch(llm, goal: goal, context: context) }
            var briefed = false
            func takeBrief() async throws {
                guard let briefing, !briefed else { return }
                briefed = true
                let waitStarted = brainNow()
                let (brief, seconds, note) = await withTaskCancellationHandler { await briefing.value } onCancel: { briefing.cancel() }
                try stillCurrent(token)
                let waited = brainNow() - waitStarted
                agent.brief = brief
                let when = waited < 0.05 ? "ready before the first look" : "held the first look \(Int(waited * 1000)) ms"
                BrainTrace.mark("brief", seconds, brief == nil ? "none: \(note)" : "\(note), \(when)", step: false)
                log("Brief", brief.map { $0.summary.isEmpty ? "Ready" : $0.summary } ?? "No brief (\(note)); acting from the request")
                // A genuinely ambiguous request: ask before acting. The reply is a new request (the session context
                // carries the question), so there is nothing to resume.
                if let ask = brief?.ask, firstStep == 1, !previewOnly {
                    let question = BrainBrief.question(ask)
                    spokenResult = question; running = false; taskIndicator = .idle; transition(.needsUser, question); savedSettings = nil
                }
            }
            defer { briefing?.cancel() }
            transition(.preparing, "Leaving Phone Agent")
            let leaving = brainNow()
            let left = previewOnly ? false : await leaveApp(pointer)
            try stillCurrent(token)
            if !left {
                for n in stride(from: Int(settings.startDelay.rounded()), through: 1, by: -1) {
                    if UIApplication.shared.applicationState == .background { break }
                    transition(.preparing, "Swipe up to the Home Screen; starting in \(n)s")
                    try await Task.sleep(nanoseconds: 1_000_000_000); try stillCurrent(token)
                }
            }
            let plan = try await agent.replan(stuck: false)  // no model call on a fresh run
            var opening = direct
            if opening == nil {  // the brief may name the app; opening it still needs no model call
                try await takeBrief()
                if running, !previewOnly, let target = agent.brief?.target {
                    opening = FastPaths.Opening(target: target, onlyOpen: false, spoken: target.name)
                }
            }
            if !running {  // the brief asked a question
            } else if let opening, UIApplication.shared.applicationState == .background {
                try await openFast(opening, agent: agent, since: brainNow(), leaving: leaving, token: token)
            } else {
                await agent.arrive(since: brainNow()); try stillCurrent(token)  // the first actor call overlaps the settle
            }
            if running { try await takeBrief() }
            if running { transition(.observing, "Planning"); log("Plan", plan) }
            var hiccups = 0, stuckReplans = 0
            rounds: for step in firstStep...max(firstStep, min(100, settings.maxSteps)) {
                if !running { break }  // the fast path already finished the goal
                try stillCurrent(token); currentStep = step; transition(.observing, "Step \(step): looking")
                do {
                    let acts = try await agent.nextActions()
                    try stillCurrent(token)
                    let seen = agent.shot, stuck = agent.repeating(acts[0])
                    var spots = [agent.pointerAt]
                    var performed: JObject?  // recorded once the next action starts, or with the batch's result
                    var replanned = false
                    batch: for (i, act) in acts.enumerated() {
                        if settings.confirmEachStep && i > 0 { break }  // one approved action per look
                        let name = act["action"]?.str ?? ""
                        if name == "replan" || (i == 0 && stuck) {
                            if let done = performed { agent.record(done, changed: nil) }
                            performed = nil; agent.record(act, changed: nil)
                            stuckReplans += 1
                            guard stuckReplans < 3 else {
                                running = false; taskIndicator = .idle; transition(.needsUser, "I'm stuck; please check the screen"); break rounds
                            }
                            transition(.observing, "Replanning")
                            log("Replanned", try await agent.replan(stuck: true))
                            replanned = true; break batch
                        }
                        // An answer is read from a screen the actor has seen: a done after gestures waits for the next look.
                        if name == "done", i > 0, agent.brief?.deliverable == .answer { break batch }
                        let a = FastAgent.agentAction(act)
                        log(a.label, a.reason); try stillCurrent(token)
                        if name == "done" {
                            var summary = a.reason
                            let answer = BrainBrief.answer(act["answer"]?.str ?? a.reason)
                            if agent.brief?.deliverable == .answer, !answer.isEmpty {  // the information itself is what a call speaks back
                                summary = answer; spokenResult = answer
                            }
                            running = false; taskIndicator = .completed; transition(.completed, summary); savedSettings = nil; break rounds
                        }
                        if name == "fail" {
                            pendingAction = a; running = false; taskIndicator = .idle; transition(.needsUser, a.reason); break rounds
                        }
                        if previewOnly {
                            pendingAction = a; running = false; taskIndicator = .idle; transition(.preview, "Plan generated: \(a.reason)"); savedSettings = nil; break rounds
                        }
                        if settings.confirmEachStep {
                            pendingAction = a; approved = false; transition(.awaitingApproval, "Waiting for confirmation: \(a.label)")
                            while !approved { try await Task.sleep(nanoseconds: 150_000_000); try stillCurrent(token) }
                            pendingAction = nil
                        }
                        if let done = performed { agent.record(done, changed: nil) }
                        performed = nil
                        try stillCurrent(token); executingAction = a; transition(.acting, "Step \(step): \(a.label)")
                        try await agent.perform(act)
                        executingAction = nil; performed = act
                        spots += BrainActions.pointerPath(act)
                        let next = i + 1 < acts.count ? acts[i + 1]["action"]?.str : nil
                        // A missed tap never opened the field: skip the rest; the actor looks again.
                        if name == "tap", next == "type" || next == "key", !settings.confirmEachStep,
                           !(await agent.settleChanged(seen: seen, spots: spots)) {
                            agent.record(act, changed: false); performed = nil; break batch
                        }
                    }
                    if !replanned, let done = performed {
                        agent.record(done, changed: await agent.settleChanged(seen: seen, spots: spots))
                    }
                    hiccups = 0
                } catch let e as CancellationError {
                    throw e
                } catch {
                    try stillCurrent(token)
                    executingAction = nil
                    let message = error.localizedDescription
                    hiccups += 1; log("Hiccup", message)
                    guard hiccups < 3 else {
                        running = false; taskIndicator = .idle; transition(.needsUser, message); break rounds
                    }
                    agent.record(["action": .str("hiccup"), "reason": .str(String(message.prefix(300)))], changed: nil)
                    await screen.settled(); try stillCurrent(token)
                    if let plan = try? await agent.replan(stuck: true) { log("Replanned", plan) }
                }
            }
            if running && token == session { running = false; taskIndicator = .failed; transition(.failed, "Reached the maximum number of steps; check the current result") }
        } catch is CancellationError {
            // A new session or Stop owns the visible state.
        } catch {
            if token == session {
                self.error = error.localizedDescription; executingAction = nil; running = false; taskIndicator = .failed; transition(.failed, "Execution interrupted: \(error.localizedDescription)")
                log("Stopped", error.localizedDescription)
            }
        }
        if token == session && !previewOnly {
            releasing = true
            await executor.ble.release()
            if token == session { releasing = false }
        }
        if token == session { loop = nil; publishRecord() }
    }
    /// Opens the goal's app without a model (FastPaths). A goal that was only "open X" is done then; otherwise, or
    /// when the app did not open, the actor carries on with the whole goal from the current screen.
    private func openFast(_ opening: FastPaths.Opening, agent: FastAgent, since: Double, leaving: Double, token: UUID) async throws {
        let name = opening.target.name, screen = brainScreen
        transition(.acting, "Opening \(name)")
        var opened = false
        do {
            opened = try await FastPaths.openApp(opening, pointer: brainPointer, screen: screen, since: since) { try self.stillCurrent(token) }
        } catch let e where e is CancellationError { throw e } catch { log("Hiccup", error.localizedDescription) }
        try stillCurrent(token)
        let timing = BrainTrace.summary()
        guard opened else {
            log("Open app", "\(name) did not open from the Home Screen; the agent takes over" + (timing.isEmpty ? "" : " · \(timing)"))
            agent.record(["action": .str("open"), "app": .str(name), "reason": .str("fast path missed")], changed: nil)
            await screen.settled(); try stillCurrent(token)
            return
        }
        log("Open app", "\(name), from the Home Screen without a model" + (timing.isEmpty ? "" : " · \(timing)"))
        agent.record(["action": .str("open"), "app": .str(name)], changed: true)
        if opening.onlyOpen {
            BrainTrace.mark("done", brainNow() - leaving, "run total, no model call", step: false)
            running = false; taskIndicator = .completed; transition(.completed, "\(name) is open"); savedSettings = nil
            return
        }
        await screen.settled(); try stillCurrent(token)  // the actor looks at the app, not its launch animation
    }
}
