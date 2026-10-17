import Foundation
import Combine
import UIKit

@MainActor
final class PhoneAgentViewModel: ObservableObject {
    static let shared = PhoneAgentViewModel()
    @Published var goal = UserDefaults.standard.string(forKey: "agent.currentGoal") ?? "" {
        didSet {
            UserDefaults.standard.set(goal, forKey: "agent.currentGoal")
            if !taskPlan.isEmpty && taskPlanDraftGoal != goal { taskPlan = []; taskPlanDraftGoal = nil; taskPlanOriginal = "" }
        }
    }
    @Published var settings: AgentSettings { didSet {
        SettingsStore.save(settings); capture.maxSide = settings.imageMaxSide; updateTaskActivity()
        let recipientChanged = oldValue.endpoint != settings.endpoint || oldValue.model != settings.model || PrivacyConsent.recipient(oldValue) != PrivacyConsent.recipient(settings)
        liveCamera.stop(clearResults: recipientChanged)
        if recipientChanged { conversation.cancel(); conversation.selectFrame(nil) }
        if queueRunning { pauseQueue(); notice = "Settings changed. The queue is paused; review before continuing." }
    } }
    @Published var taskPlan: [String] = []
    private(set) var taskPlanDraftGoal: String?
    private(set) var taskPlanOriginal = ""
    func useTaskPlan(_ items: [String], original: String) {
        let list = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = original.isEmpty ? list : "Overall task and constraints:\n" + original + "\n\nSteps:\n" + list
        taskPlanOriginal = original; taskPlanDraftGoal = combined; taskPlan = items; goal = combined
    }
    func removeTaskPlan() {
        guard !taskPlan.isEmpty else { return }
        let original = taskPlanOriginal
        let ownsDraft = goal == taskPlanDraftGoal
        taskPlan = []; taskPlanDraftGoal = nil; taskPlanOriginal = ""
        if ownsDraft { goal = original }
    }
    @Published var workbenchHasDraft = false
    @Published var notice = ""
    @Published var showPrivacyConsent = false
    @Published var showPrivacyPolicy = false
    @Published var showPreparation = false
    private var pendingConsentStart = false
    let history = TaskHistoryStore()
    let taskQueue = TaskQueueStore()
    @Published private(set) var queueRunning = false
    @Published private(set) var queueSwitching = false
    @Published private(set) var queueStatus = "Queue not running"
    private var queueActiveID: UUID?
    private var queueGeneration = UUID()
    private var queueOperation: Task<Void, Never>?
    private var queueAdvance: Task<Void, Never>?
    private var handlingQueueFailure = false
    let memories = MemoryStore()
    let recordings = RecordingStore()
    @Published private(set) var recordingAudioOwner: UUID?
    func reserveRecordingAudio(_ id: UUID) -> Bool {
        guard recordingAudioOwner == nil, !engine.running, !engine.releasing, !queueRunning, !queueSwitching,
              !voicePending, voiceMode == nil, !manualBusy, !calibrating, !speech.usingAudio else { return false }
        recordingAudioOwner = id; conversation.cancel(); liveCamera.stop(); camera.stop(); return true
    }
    func releaseRecordingAudio(_ id: UUID) { if recordingAudioOwner == id { recordingAudioOwner = nil } }
    let camera = CameraService()
    let liveCamera = LiveCameraObserver()
    let taskActivity = TaskActivityController()
    var interactionBusy: Bool {
        recordingAudioOwner != nil || queueSwitching || engine.running || engine.releasing || manualBusy || voicePending
    }

    var consentReady: Bool { PrivacyConsent.allowed(settings) }
    var calibrationReady: Bool {
        guard let c = executor.calibration else { return false }
        return c.usable && c.peripheralID == ble.selectedID
    }
    var modelReady: Bool {
        guard let endpoint = try? ModelEndpointPolicy.url(settings.endpoint), endpoint.path.hasSuffix("/chat/completions") else { return false }
        return !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SettingsStore.apiKey(for: settings.endpoint).isEmpty
    }
    var preparationReady: Bool {
        recordingAudioOwner == nil && modelReady && consentReady && !settings.usesBedrock && capture.running && capture.frame?.fullDisplay == true &&
            (settings.previewOnly || (ble.ready && calibrationReady))
    }
    func requestConsent() { pendingConsentStart = false; showPrivacyConsent = true }
    func acceptConsent() {
        guard modelReady else { notice = "Save a valid model configuration first"; return }
        PrivacyConsent.grant(settings); showPrivacyConsent = false; objectWillChange.send()
        let shouldStart = pendingConsentStart; pendingConsentStart = false
        if shouldStart { startAgent() }
    }
    func declineConsent() { pendingConsentStart = false; showPrivacyConsent = false }
    func revokeConsent() {
        stop(); capture.stop(); PrivacyConsent.revoke(); objectWillChange.send()
        notice = "AI data consent revoked and screen sharing stopped"
    }
    func resumeAgent() {
        haltQueue("Switched to continuing the current task manually")
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return }
        guard preparationReady else { showPreparation = true; notice = "When setup is done, tap Continue Task"; return }
        notice = ""; engine.resume(settings: settings)
    }
    func removeTask(_ id: UUID) {
        guard !engine.running, !engine.releasing else { return }
        guard !taskQueue.items.contains(where: { $0.id == id }) else { notice = "Remove this task from the queue before deleting its history"; return }
        if engine.currentRecord?.id == id { engine.discardCurrent() }
        history.remove(id)
    }
    func clearHistory() {
        guard !engine.running, !engine.releasing else { return }
        guard taskQueue.items.isEmpty else { notice = "Clear the task queue before clearing history"; return }
        engine.discardCurrent(); history.clear()
    }
    @Published var manualBusy = false
    @Published var calibrating = false
    @Published private(set) var voicePending = false
    @Published var voiceRequestID = UUID()
    @Published var voiceMode: VoiceInputMode?
    @Published var showAssistant = false
    var cancelCalibration: (() -> Void)?
    let ble = BLETransport()
    let capture = CaptureService()
    let executor: MouseExecutor
    let engine: AgentEngine
    let call = CallController()
    lazy var speech = VoiceController()
    lazy var conversation = AssistantConversation()
    lazy var pip = AgentPiPController(engine: engine, stopTask: { [weak self] in self?.stop() })
    private var observers = Set<AnyCancellable>()
    /// Earlier requests and how they ended, so call follow-ups ("send it", "him", "this chat") keep their meaning.
    private(set) var session = SessionContext()
    private var manual: Task<Void, Never>?
    private var voicePreparation: Task<Void, Never>?
    private var voiceGeneration = UUID()
    init() {
        let restoredSettings = SettingsStore.load()
        settings = restoredSettings
        SettingsStore.adoptLegacyCredential(for: restoredSettings.endpoint)
        executor = MouseExecutor(ble: ble)
        engine = AgentEngine(capture: capture, executor: executor)
        capture.maxSide = settings.imageMaxSide
        for publisher in [ble.objectWillChange, capture.objectWillChange, engine.objectWillChange, history.objectWillChange, taskQueue.objectWillChange, memories.objectWillChange, camera.objectWillChange, liveCamera.objectWillChange, taskActivity.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        }
        engine.$taskIndicator.removeDuplicates().sink { [weak self] value in
            self?.ble.setTaskIndicator(value)
        }.store(in: &observers)
        engine.$currentRecord.combineLatest(engine.$phase, engine.$currentStep, engine.$releasing).throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true).sink { [weak self] _, _, _, _ in self?.updateTaskActivity() }.store(in: &observers)
        engine.onRecord = { [weak self] record in
            self?.history.upsert(record); self?.recordQueueProgress(record); self?.noteSession(record)
        }
        FastAgent.sessionContext = { [weak self] in
            guard let self else { return "" }
            return SessionContext.block(self.session.inherited(inCall: self.call.isActive))
        }
        engine.$phase.removeDuplicates().sink { [weak self] phase in
            // In a call the voice agent reports results; local speech would also take over the call's audio session.
            guard let self, self.recordingAudioOwner == nil, self.settings.spokenFeedback == true, !self.call.isActive, UIApplication.shared.applicationState == .active else { return }
            if phase == .completed { self.speech.speak("Task complete. " + String(self.engine.state.prefix(140))) }
            else if phase == .needsUser { self.speech.speak("The task needs your attention. " + String(self.engine.state.prefix(140))) }
        }.store(in: &observers)
        speech.prepareAudio = { [weak self] in
            guard self?.recordingAudioOwner == nil else { throw AgentError.message("End the current audio session before using voice") }
            try await self?.pip.suspendForVoice()
            guard self?.recordingAudioOwner == nil else { throw AgentError.message("An audio session is running. Try again shortly.") }
        }
        speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        conversation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observers)
        capture.onStop = { [weak self] in
            self?.cancelVoicePreparation(message: "Screen sharing stopped; the voice task was canceled")
            self?.engine.stop(reason: "Screen sharing stopped")
        }
        AgentActivityControls.handler = { [weak self] taskID, sessionID, control in
            await self?.performActivityControl(taskID: taskID, sessionID: sessionID, control: control)
        }
    }
    private func updateTaskActivity() {
        taskActivity.update(record: engine.currentRecord, phase: engine.phase, step: engine.currentStep, action: engine.executingAction?.label,
                            enabled: settings.liveTaskStatus == true, sessionID: engine.activityControlSessionID,
                            releasing: engine.releasing, canPause: engine.running, canStop: engine.hasCurrentTask)
    }
    private func performActivityControl(taskID: UUID, sessionID: UUID, control: ActivityTaskControl) async {
        // Validate before the first suspension. An archived card, old run of the
        // same queued task, completed task or disabled feature has no authority.
        guard settings.liveTaskStatus == true, engine.currentRecord?.id == taskID,
              engine.activityControlSessionID == sessionID, taskActivity.represents(taskID),
              engine.hasCurrentTask else {
            updateTaskActivity(); await taskActivity.flush(); return
        }
        switch control {
        case .pause:
            guard engine.running else { updateTaskActivity(); await taskActivity.flush(); return }
            _ = pauseTask()
            notice = "Paused from the Live Activity; task progress was kept"
        case .stop:
            guard ![AgentPhase.completed, .stopped, .idle, .preview].contains(engine.phase) else { return }
            stop(); notice = "Stopped from the Live Activity; queued tasks were kept"
        }
        // Cancellation is synchronous; release may wait for a submitted OS / BLE
        // operation. Show that distinction before waiting, and bound this intent.
        let settledSession = engine.activityControlSessionID
        updateTaskActivity(); await taskActivity.flush()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while engine.releasing && ProcessInfo.processInfo.systemUptime < deadline {
            guard engine.currentRecord?.id == taskID, engine.activityControlSessionID == settledSession else { return }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        guard engine.currentRecord?.id == taskID, engine.activityControlSessionID == settledSession else { return }
        updateTaskActivity(); await taskActivity.flush()
    }
    func startAgent() {
        guard recordingAudioOwner == nil else { notice = "End the current audio session before running a phone task"; return }
        if engine.hasCurrentTask || queueRunning || taskQueue.pendingCount > 0 { enqueueDraft(); return }
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else { return }
        guard !engine.releasing else { return }
        speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancel(); notice = ""
        guard modelReady else { notice = "Set up a model service first"; showPreparation = true; return }
        guard consentReady else { pendingConsentStart = true; showPrivacyConsent = true; return }
        guard !settings.usesBedrock else { notice = "The phone agent needs an OpenAI-compatible endpoint; Bedrock works for chat only"; return }
        guard preparationReady else { showPreparation = true; return }
        engine.start(task: goal, settings: settings)
        if engine.running { taskPlan = [] }
    }
    func requestVoiceTask(_ text: String, supersede: Bool = false) -> String {
        guard recordingAudioOwner == nil else { return "End the current audio session before starting a task." }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "Enter a task of 1 to 4,000 characters." }
        let route = VoiceTaskRequestRouter.route(
            hasCurrentTask: engine.hasCurrentTask,
            pendingTaskCount: taskQueue.pendingCount,
            queueRunning: queueRunning,
            engineRunning: engine.running,
            queueSwitching: queueSwitching,
            engineReleasing: engine.releasing,
            voicePending: voicePending,
            manualBusy: manualBusy,
            calibrating: calibrating || executor.calibrationInProgress,
            supersede: supersede
        )
        switch route {
        case .queue:
            return requestQueuedVoiceTask(text, priority: false)
        case .busy:
            return "An action or calibration is in progress. Try a new task shortly."
        case .start:
            break
        }
        goal = text
        guard consentReady else {
            pendingConsentStart = false; showPrivacyConsent = true
            notice = "Confirm sending screen and task data to the current AI service, then give the voice command again"
            return notice
        }
        guard !SettingsStore.apiKey().isEmpty else {
            notice = "Save an API key in Model & Settings first"
            return notice
        }
        liveCamera.stop(); camera.stop(); conversation.cancel()
        guard settings.previewOnly || executor.calibration?.usable == true else {
            notice = "Calibrate the mouse in Device & Calibration first"
            return notice
        }
        goal = text; voiceRequestID = UUID(); voicePending = true
        notice = "Voice task received. Preparing screen and mouse. When the system sharing window appears, choose the entire screen."
        let token = UUID(); voiceGeneration = token
        // Only this live, cancellable request may start. It isn't restored on launch.
        var taskSettings = settings
        taskSettings.startDelay = max(5, taskSettings.startDelay)
        voicePreparation = Task { [weak self] in
            await self?.prepareVoiceTask(text, settings: taskSettings, token: token)
        }
        return "Task received. Phone Agent is getting ready. If a sharing window appears, confirm full-screen sharing."
    }
    // Phone Agent need not be in front: in a call the user is usually in another app, and the fast agent works from
    // whatever is on screen. Only starting screen sharing (system picker) or scanning for the mouse needs the app open.
    private func prepareVoiceTask(_ text: String, settings: AgentSettings, token: UUID) async {
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 90
        var attemptedCapture = capture.running || capture.waitingForPicker
        var nextScan = 0.0
        while !Task.isCancelled, token == voiceGeneration, voicePending {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                cancelVoicePreparation(message: "Setup timed out and the voice task was canceled. Check screen sharing and the mouse connection, then try again.")
                return
            }
            let appState = UIApplication.shared.applicationState
            if appState == .background, ProcessInfo.processInfo.systemUptime - started > 6,
               !capture.running || (!settings.previewOnly && !ble.ready) {
                cancelVoicePreparation(message: capture.running
                    ? "The mouse accessory isn't connected. Open Phone Agent to reconnect it, then ask again."
                    : "Screen sharing is off. Open Phone Agent to turn it on, then ask again.")
                return
            }
            if appState == .active, !settings.previewOnly, !ble.ready, ProcessInfo.processInfo.systemUptime >= nextScan {
                ble.scan(); nextScan = ProcessInfo.processInfo.systemUptime + 10
            }
            if appState == .active, !attemptedCapture, !capture.running, !capture.waitingForPicker {
                attemptedCapture = true; capture.start()
            }
            if attemptedCapture, !capture.error.isEmpty {
                cancelVoicePreparation(message: "Screen sharing failed; the voice task was canceled: \(capture.error)")
                return
            }
            if let frame = capture.frame, !frame.fullDisplay {
                cancelVoicePreparation(message: "Voice task canceled. Choose full-screen sharing, then give the command again.")
                return
            }
            if capture.running, let frame = capture.frame, frame.fullDisplay,
               (0..<1.5).contains(Date().timeIntervalSince(frame.confirmedAt)), settings.previewOnly || ble.ready {
                if !settings.previewOnly {
                    do { _ = try executor.validateCalibration(frame: frame) }
                    catch {
                        cancelVoicePreparation(message: "Voice task canceled: \(error.localizedDescription)")
                        return
                    }
                }
                voicePending = false; voicePreparation = nil
                notice = ""; engine.start(task: text, settings: settings)
                if !engine.running { notice = engine.error }
                return
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
        }
    }
    private func cancelVoicePreparation(message: String? = nil) {
        let wasPending = voicePending
        voiceGeneration = UUID(); voicePreparation?.cancel(); voicePreparation = nil; voicePending = false
        if wasPending, let message { notice = message }
    }
    func stop() {
        haltQueue("Queue stopped; waiting tasks were kept")
        liveCamera.stop()
        camera.stop()
        speech.cancel(); conversation.cancel(); voiceMode = nil
        pendingConsentStart = false
        cancelVoicePreparation(message: "Voice task canceled")
        if calibrating { cancelCalibration?() }
        manual?.cancel(); manual = nil; manualBusy = false
        engine.stop()
    }
    /// A task that ended (or was replaced) joins the session context with where the phone was left.
    private func noteSession(_ record: PhoneTaskRecord) {
        guard ![.running, .preview].contains(record.outcome) else { return }
        session.note(id: record.id, request: record.goal, outcome: SessionContext.outcome(record.outcome, record.summary),
                     screen: FastAgent.lastLook, at: record.updatedAt)
    }
    func startCall() {
        guard !call.isActive else { return }
        session.clear()  // a new conversation
        speech.cancel(); conversation.cancel(); voiceMode = nil
        Task { await call.start(runTask: { [weak self] in await self?.runVoiceTask($0) ?? "The app is closing." },
                                stopTask: { [weak self] in await self?.stopVoiceTask() ?? "Stopped." }) }
    }
    func endCall() { Task { await call.end() } }
    /// A call request is what the user wants done now: it replaces whatever ran before (running, waiting for help,
    /// preparing or queued) instead of queueing behind it, and the reply says what actually happened.
    func runVoiceTask(_ instruction: String) async -> String {
        if queueRunning || queueSwitching { haltQueue("A call request took over; queued tasks were kept") }
        cancelVoicePreparation()
        if engine.running || engine.canResume {
            // A queued task keeps its place (paused); anything else is ended so the new request starts clean.
            if let id = engine.currentRecord?.id, id == queueActiveID { engine.pause() } else { engine.stop() }
        }
        let settle = ProcessInfo.processInfo.systemUptime + 6
        while (engine.releasing || queueSwitching) && ProcessInfo.processInfo.systemUptime < settle {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return "Canceled." }
        }
        guard !engine.releasing, !queueSwitching else { return "The phone is still finishing the last action. Ask again in a moment." }
        queueActiveID = nil; engine.discardCurrent()
        let reply = requestVoiceTask(instruction, supersede: true)
        guard voicePending || engine.running else { return reply }
        while voicePending || engine.running || engine.releasing {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return "Replaced by the newer request." }
        }
        guard let record = engine.currentRecord else { return notice.isEmpty ? reply : notice }
        // The brief's clarifying question, or the information the user asked for, is spoken as it is.
        if let direct = engine.spokenResult, [.completed, .needsUser].contains(engine.phase) { return direct }
        let summary = String(record.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        switch engine.phase {
        case .completed: return summary.isEmpty ? "Done." : "Done. " + summary
        case .needsUser: return "I need your help on the phone: " + summary
        case .failed: return "That didn't work: " + summary
        case .paused: return "The task is paused."
        case .stopped, .idle: return "The task was stopped."
        default: return summary.isEmpty ? "Finished." : summary
        }
    }
    func stopVoiceTask() async -> String {
        guard engine.running || engine.releasing || voicePending || queueRunning || engine.canResume else { return "Nothing is running on the phone." }
        let title = engine.running || engine.canResume ? engine.currentRecord?.title : nil
        stop(); notice = "Task stopped"
        return title.map { "I stopped: \($0)." } ?? "I stopped the phone task."
    }
    @discardableResult
    func pauseTask(handoff: Bool = false) -> String {
        haltQueue(handoff ? "You took over; the queue is paused" : "Queue paused")
        let wasPreparing = voicePending
        cancelVoicePreparation(message: "Voice task setup canceled")
        guard engine.hasCurrentTask else {
            notice = wasPreparing ? "Canceled the waiting task" : "No task is running"
            return notice
        }
        if handoff { engine.handoff() } else { engine.pause() }
        notice = handoff ? "Handed to you. When you're done, say \"Continue\"" : "Paused; task progress was kept"
        return notice
    }
    @discardableResult
    func beginVoice(_ mode: VoiceInputMode) -> String {
        guard recordingAudioOwner == nil else { return "End the current audio session before using voice." }
        guard !queueSwitching, !calibrating, !manualBusy, !executor.calibrationInProgress else { notice = "Wait for task switching, calibration, or manual input to finish"; return notice }
        if mode == .supplement {
            guard engine.hasCurrentTask else { notice = "There's no task to add instructions to"; return notice }
            _ = pauseTask()
        } else if engine.running || voicePending { _ = pauseTask() }
        speech.cancel(); liveCamera.stop(); camera.stop(); speech.onSilence = nil; conversation.cancel(); voiceMode = mode; voiceRequestID = UUID()
        return mode == .supplement ? "Task paused. Say your additional instructions." : "Say it in Phone Agent."
    }
    @discardableResult
    func supplementTask(_ text: String) -> String {
        haltQueue("After adding instructions, continue the task or queue manually")
        do { try engine.amendTask(text); notice = "Instructions added. Say \"Continue\" to run them." }
        catch { notice = error.localizedDescription }
        return notice
    }
    func resumeVoiceTask() async -> String {
        guard !Task.isCancelled else { return "Continue request canceled." }
        haltQueue("Switched to continuing the current task by voice")
        guard engine.hasCurrentTask else { return "There's no task to continue." }
        let deadline = Date().addingTimeInterval(5)
        while engine.releasing && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return "Continue request canceled." }
        }
        guard !queueSwitching, !engine.releasing, !voicePending, !manualBusy, !calibrating else { return "Releasing input or handling another action. Continue shortly." }
        guard engine.canResume else { return engine.running ? "The task is running." : "This task can't continue. Create a new task." }
        guard preparationReady else { showPreparation = true; notice = "Restore the screen, model, or accessory, then say \"Continue\""; return notice }
        guard !Task.isCancelled else { return "Continue request canceled." }
        speech.cancel(); conversation.cancel(); voiceMode = nil; notice = ""
        engine.resume(settings: settings, delay: max(5, settings.startDelay))
        voiceRequestID = UUID()
        return engine.running ? "Continuing the task." : engine.error
    }
    func handleVoiceCommand(_ command: VoiceCommand) async -> String {
        switch command {
        case .pause: return pauseTask()
        case .handoff: return pauseTask(handoff: true)
        case .stop: stop(); notice = "Task stopped"; return notice
        case .resume: return await resumeVoiceTask()
        case .supplement: return beginVoice(.supplement)
        }
    }
    func submitVoiceText(_ text: String, mode: VoiceInputMode) async -> String {
        guard !Task.isCancelled else { return "Submission canceled." }
        if let command = VoiceCommand.parse(text) { return await handleVoiceCommand(command) }
        switch mode {
        case .task: return requestVoiceTask(text)
        case .supplement: return supplementTask(text)
        case .question:
            showAssistant = true; conversation.draft = text
            return "Your question is in the conversation. Review it, then send."
        }
    }
    func manualAction(_ block: @escaping () async throws -> Void) {
        guard !queueSwitching, !engine.running, !manualBusy, !voicePending, !calibrating, !executor.calibrationInProgress else { return }
        notice = ""; manualBusy = true
        manual = Task {
            do { try await block() }
            catch is CancellationError { }
            catch { notice = error.localizedDescription }
            await ble.release(); manualBusy = false
        }
    }
    func saveKey(_ key: String) {
        do { try SettingsStore.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); notice = "Model settings saved" }
        catch { notice = error.localizedDescription }
    }
}

extension PhoneAgentViewModel {
    private func queuedSnapshot() -> QueuedPhoneTask? {
        guard engine.hasCurrentTask, let record = engine.currentRecord, let settings = engine.currentSettings else { return nil }
        return QueuedPhoneTask(record: record, settings: settings, step: engine.currentStep, started: true,
                               state: engine.running ? .running : .suspended)
    }
    func enqueueDraft(priority: Bool = false) {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12000 else { notice = "Task text must be 1–12,000 characters"; return }
        let item = QueuedPhoneTask(record: PhoneTaskRecord(title: String(text.prefix(36)), goal: text,
                    outcome: .paused, summary: "Added to queue; not run yet"), settings: settings)
        do {
            try taskQueue.append(item)
            goal = ""; taskPlan = []; taskPlanOriginal = ""; taskPlanDraftGoal = nil
            notice = priority ? "Priority task added; saving the current task's progress" : "Added to queue. Tap Run Queue to run tasks in order."
            if priority { runTaskQueue(first: item.id) }
        } catch { notice = error.localizedDescription }
    }
    // This authority is process-local. It is never restored from queue.json.
    private func haltQueue(_ reason: String) {
        queueRunning = false; queueGeneration = UUID()
        queueOperation?.cancel(); queueOperation = nil
        queueAdvance?.cancel(); queueAdvance = nil
        queueStatus = reason
    }
    func pauseQueue() {
        haltQueue("Queue paused; progress was kept")
        engine.pause()
    }
    private func waitForQueueSettlement(_ token: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !engine.executionSettled {
            try Task.checkCancellation()
            guard token == queueGeneration else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AgentError.message("The previous run hasn't finished. The queue is paused; try again shortly.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try Task.checkCancellation()
        guard token == queueGeneration else { throw CancellationError() }
    }
    func runTaskQueue(first selected: UUID? = nil) {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !executor.calibrationInProgress else { return }
        haltQueue("Preparing queue")
        let current = queuedSnapshot()
        do {
            try taskQueue.transaction { items in
                if let current {
                    if let index = items.firstIndex(where: { $0.id == current.id }) { items[index] = current }
                    else { items.insert(current, at: 0) }
                }
                if let selected {
                    guard let index = items.firstIndex(where: { $0.id == selected }), items[index].resumable else {
                        throw AgentError.message("This task has ended and can't continue")
                    }
                    var item = items.remove(at: index)
                    item.state = current?.id == selected && engine.running ? .running : .waiting
                    item.note = "You chose to run this first"; items.insert(item, at: 0)
                    if let current, current.id != selected, let old = items.firstIndex(where: { $0.id == current.id }) {
                        let interrupted = items.remove(at: old); items.insert(interrupted, at: 1)
                    }
                } else if let current, let index = items.firstIndex(where: { $0.id == current.id }) {
                    var item = items.remove(at: index); item.state = engine.running ? .running : .waiting
                    items.insert(item, at: 0)
                } else if let index = items.firstIndex(where: { $0.resumable }) {
                    // One explicit Run resumes the next item, not every interrupted item.
                    items[index].state = .waiting
                }
            }
        } catch { notice = error.localizedDescription; queueStatus = "Queue not started"; return }
        queueRunning = true; queueActiveID = current?.id; notice = ""
        if let current, engine.running, selected == nil || selected == current.id {
            queueStatus = "Next item runs after the current task finishes"; return
        }
        let token = queueGeneration; queueSwitching = true
        if engine.running { engine.pause() }
        queueOperation = Task { [weak self] in
            guard let self else { return }
            defer { self.queueSwitching = false; self.queueOperation = nil }
            do {
                try await self.waitForQueueSettlement(token)
                if let current, selected != nil, selected != current.id {
                    try self.taskQueue.update(current.id) { item in
                        // Failures and user-required steps need a separate explicit review.
                        item.state = [.running, .paused].contains(current.record.outcome) ? .waiting : .suspended
                        item.note = "Resumes from a fresh screen after the priority task; the last step may have partly run."
                    }
                }
                let target = selected ?? current?.id
                if let target { try self.taskQueue.update(target) { $0.state = .waiting } }
                self.engine.discardCurrent(); self.queueActiveID = nil
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
    }
    private func launchNextQueued(_ token: UUID) throws {
        guard recordingAudioOwner == nil else { throw AgentError.message("End the current audio session before running the queue") }
        guard token == queueGeneration, queueRunning else { throw CancellationError() }
        guard UIApplication.shared.applicationState == .active else { throw AgentError.message("Return to Phone Agent and tap Run Queue; the next item doesn't start in the background") }
        guard let item = taskQueue.items.first(where: { $0.resumable }) else {
            haltQueue("Queue complete"); return
        }
        guard item.state == .waiting else { throw AgentError.message("The next item needs your review. Tap its Continue button to run it.") }
        let config = item.settings
        guard config.endpoint == settings.endpoint, config.model == settings.model,
              PrivacyConsent.recipient(config) == PrivacyConsent.recipient(settings) else {
            throw AgentError.message("Model settings changed. Review the queue and choose Use Current Settings before continuing.")
        }
        guard (try? ModelEndpointPolicy.url(config.endpoint)).map({ $0.path.hasSuffix("/chat/completions") }) == true &&
              !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !SettingsStore.apiKey(for: config.endpoint).isEmpty,
              PrivacyConsent.allowed(config) else {
            throw AgentError.message("Save a model key and confirm AI data consent before running the queue")
        }
        // Persist the reservation before any model request or input is started.
        try taskQueue.update(item.id) { $0.state = .running; $0.note = "Running"; $0.started = true; $0.settings = config }
        queueActiveID = item.id
        do {
            speech.cancel(); liveCamera.stop(); camera.stop(); conversation.cancel(); voiceMode = nil
            try engine.restoreQueued(record: item.record, settings: config, step: item.step, previouslyStarted: item.started)
            queueStatus = "Running: " + item.record.title
        } catch {
            try? taskQueue.update(item.id) { $0.state = .suspended; $0.note = String(error.localizedDescription.prefix(1000)) }
            queueActiveID = nil; throw error
        }
    }
    private func recordQueueProgress(_ record: PhoneTaskRecord) {
        guard queueActiveID == record.id, !handlingQueueFailure else { return }
        do {
            try taskQueue.update(record.id) { item in
                item.record = record; item.step = engine.currentStep; item.started = true
                if let settings = engine.currentSettings { item.settings = settings }
                item.note = String(record.summary.prefix(1000))
                switch record.outcome {
                case .running: item.state = .running
                case .completed: item.state = .completed
                case .stopped: item.state = .stopped
                case .preview: item.state = .preview
                default: item.state = .suspended
                }
            }
        } catch {
            handlingQueueFailure = true
            haltQueue("Couldn't save the queue record; execution paused")
            if engine.running { engine.pause() }
            notice = taskQueue.error.isEmpty ? error.localizedDescription : taskQueue.error
            handlingQueueFailure = false; return
        }
        if record.outcome == .completed, queueRunning, !queueSwitching {
            scheduleQueueAdvance(after: record.id)
        } else if record.outcome != .running, record.outcome != .completed, !queueSwitching {
            haltQueue("Current task: " + record.outcome.label + ". The queue is waiting for you.")
        }
    }
    private func scheduleQueueAdvance(after id: UUID) {
        guard queueAdvance == nil else { return }
        let token = queueGeneration
        queueAdvance = Task { [weak self] in
            guard let self else { return }
            defer { self.queueAdvance = nil }
            do {
                try await self.waitForQueueSettlement(token)
                guard self.queueActiveID == id, self.engine.currentRecord?.id == id else { throw CancellationError() }
                self.queueActiveID = nil; self.engine.discardCurrent()
                try self.launchNextQueued(token)
            } catch is CancellationError { }
            catch { self.haltQueue(error.localizedDescription); self.notice = error.localizedDescription }
        }
    }
    func useCurrentQueueConfiguration(_ id: UUID) {
        guard !queueRunning, !queueSwitching, !engine.running, !engine.releasing else { return }
        do {
            try taskQueue.update(id) { $0.settings = settings; $0.note = "Switched to current settings. Check the run mode before continuing." }
            if id == engine.currentRecord?.id, engine.canResume { engine.configurePausedTask(settings: settings) }
        }
        catch { notice = error.localizedDescription }
    }
    func moveQueuedTask(_ id: UUID, by offset: Int) {
        guard !queueRunning, !queueSwitching else { return }
        do { try taskQueue.move(id, by: offset) } catch { notice = error.localizedDescription }
    }
    func removeQueuedTask(_ id: UUID) {
        guard !queueRunning, !queueSwitching, !engine.releasing else { return }
        guard id != engine.currentRecord?.id || !engine.hasCurrentTask else { notice = "End the current task before removing its queue entry"; return }
        do { try taskQueue.remove(id) } catch { notice = error.localizedDescription }
    }
    @discardableResult
    func requestQueuedVoiceTask(_ text: String, priority: Bool) -> String {
        guard !queueSwitching, !voicePending, !calibrating, !manualBusy, !engine.releasing else { return "Wait for task switching, calibration, or input release to finish before adding a task." }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return "Enter a task of 1–4,000 characters." }
        goal = text; enqueueDraft(priority: priority); voiceRequestID = UUID()
        return notice
    }
    func clearTaskQueue() {
        guard !queueRunning, !queueSwitching, !engine.running, !engine.releasing else { return }
        do { try taskQueue.clear(); queueActiveID = nil; notice = "Queue cleared. Actions already performed are not undone." }
        catch { notice = error.localizedDescription }
    }
}
