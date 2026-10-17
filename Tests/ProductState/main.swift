import Foundation

@main struct ProductStateChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description); checks += 1
        }
        func voiceRoute(current: Bool = false, pending: Int = 0, queueRunning: Bool = false,
                        engineRunning: Bool = false, switching: Bool = false, releasing: Bool = false,
                        voicePending: Bool = false, manualBusy: Bool = false, calibrating: Bool = false) -> VoiceTaskRequestRoute {
            VoiceTaskRequestRouter.route(hasCurrentTask: current, pendingTaskCount: pending,
                                         queueRunning: queueRunning, engineRunning: engineRunning,
                                         queueSwitching: switching, engineReleasing: releasing,
                                         voicePending: voicePending, manualBusy: manualBusy,
                                         calibrating: calibrating)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PhoneAgentConsentChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite); PrivacyConsent.revoke() }
        var settings = AgentSettings(); settings.startDelay = 0
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Consent must be explicit")
        PrivacyConsent.grant(settings, defaults: defaults)
        expect(PrivacyConsent.allowed(settings, defaults: defaults), "Authorized recipient should be usable")
        var changed = settings; changed.endpoint = "https://other.example/v1/chat/completions"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Changed recipient needs new consent")
        changed = settings; changed.providerName = "Changed recipient"
        expect(!PrivacyConsent.allowed(changed, defaults: defaults), "Provider name change invalidates consent")
        defaults.set(Data("corrupt".utf8), forKey: "agent.aiConsent.v1")
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Malformed grants fail closed")
        PrivacyConsent.grant(settings, defaults: defaults); PrivacyConsent.revoke(defaults: defaults)
        expect(!PrivacyConsent.allowed(settings, defaults: defaults), "Revocation must take effect")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        object.removeValue(forKey: "providerName")
        let migrated = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: object))
        expect(migrated.endpoint == settings.endpoint && migrated.providerName == nil, "Old settings retain endpoint")

        let path = directory.appendingPathComponent("tasks.json")
        let store = TaskHistoryStore(url: path)
        let original = PhoneTaskRecord(title: "Original", goal: "Original goal")
        store.upsert(original); store.rename(original.id, title: "Renamed")
        expect(store.records[0].title == "Renamed", "Rename preserves identity")
        expect(store.records[0].goal == "Original goal", "Rename does not change task instructions")
        let reloaded = TaskHistoryStore(url: path)
        expect(reloaded.records[0].outcome == .interrupted, "Restart never restores an active task")
        expect(reloaded.records[0].id == original.id, "Stored task identity survives restart")
        for i in 0..<55 { store.upsert(PhoneTaskRecord(title: "Task \(i)", goal: "Offline")) }
        expect(store.records.count == 50, "History retention is bounded")
        let newest = store.records[0].id; store.remove(newest)
        expect(!store.records.contains { $0.id == newest }, "Delete persists")
        expect(TaskHistoryStore(url: path).records.count == 49, "Deletion survives reload")
        let corrupt = Data("broken document".utf8); try corrupt.write(to: path)
        let broken = TaskHistoryStore(url: path)
        expect(!broken.error.isEmpty, "Corrupt history shows a recoverable error")
        broken.upsert(original)
        let preserved = try Data(contentsOf: path)
        expect(preserved == corrupt, "Corrupt file must not be overwritten")
        broken.clear(); expect(broken.records.isEmpty && broken.error.isEmpty, "Explicit clear restores storage")
        broken.upsert(original); expect(broken.records.count == 1, "Storage works after clear")

        func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                precondition(Date() < deadline, "State transition timed out")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let capture = CaptureService(), executor = MouseExecutor()
        let engine = AgentEngine(capture: capture, executor: executor)
        let tap = "THINK: the button is there\nDO: tap 500 500"
        PrivacyConsent.revoke(); ModelProbe.calls = 0
        engine.start(task: "Offline task", settings: settings)
        expect(!engine.running && ModelProbe.calls == 0, "Missing consent blocks inference")
        var bedrock = settings; bedrock.endpoint = "https://bedrock-runtime.us-east-1.amazonaws.com/model"
        PrivacyConsent.grant(bedrock); engine.start(task: "Offline task", settings: bedrock)
        expect(!engine.running && engine.error.contains("Bedrock"), "Bedrock endpoints do not run phone tasks")
        PrivacyConsent.grant(settings)
        ModelProbe.gestureDelay = 1_000_000_000
        ModelProbe.reply = tap
        engine.start(task: "Offline task", settings: settings)
        try await waitUntil { engine.phase == .acting }
        engine.pause()
        expect(engine.phase == .paused && !engine.running, "Pause cancels execution")
        expect(engine.releasing, "Pause closes input before allowing resume")
        engine.resume()
        expect(ModelProbe.calls == 1, "Resume cannot race old release")
        try await waitUntil { !engine.releasing }
        expect(executor.ble.releases > 0 && engine.canResume, "Paused task becomes resumable after cleanup")
        ModelProbe.gestureDelay = 0; ModelProbe.reply = "THINK: it worked\nDO: done Verified offline result"
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(ModelProbe.gestures == ["tap"], "Resume does not replay the interrupted action")
        expect(ModelProbe.calls == 2, "Resume obtains a new observation")
        expect(engine.currentRecord?.outcome == .completed, "Completion reaches the history record")
        expect(!engine.canResume, "Completed task cannot resume")

        ModelProbe.reply = "THINK: a sign-in screen\nDO: fail Offline human handoff"
        engine.start(task: "Needs human", settings: settings)
        try await waitUntil { engine.phase == .needsUser && !engine.releasing }
        expect(engine.canResume && engine.pendingAction?.kind == .ask_user, "Human handoff retains task context")
        ModelProbe.reply = "THINK: signed in\nDO: done Human issue resolved"
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(engine.pendingAction == nil, "Resume discards the old pending action")

        ModelProbe.delay = 1_000_000_000; ModelProbe.reply = tap
        engine.start(task: "Cancel inference", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(engine.phase == .stopped && !engine.canResume, "Explicit stop ends the session")
        expect(ModelProbe.gestures == ["tap"], "Cancelled inference never executes its plan")
        expect(engine.currentRecord?.outcome == .stopped, "Stop is persisted")
        expect(VoiceCommand.parse("Assistant, pause.") == .pause, "Wake prefix and punctuation support a local pause")
        expect(VoiceCommand.parse("Hey assistant, help me pause the task") == .pause, "Wake prefix and natural pause wording are recognized")
        expect(VoiceCommand.parse("Please pause the current task") == .pause, "Polite pause command is recognized")
        expect(VoiceCommand.parse("Hey assistant, I'll take over") == .handoff, "Wake prefix supports human handoff")
        expect(VoiceCommand.parse("Hey assistant, continue the task") == .resume, "Wake prefix supports resume")
        expect(VoiceCommand.parse("Hey assistant, stop the task") == .stop, "Wake prefix supports stop")
        expect(VoiceCommand.parse("Hey assistant, add a requirement") == .supplement, "Wake prefix supports supplemental instructions")
        expect(VoiceCommand.parse("Hey assistant hey assistant, hold on") == .pause, "Repeated wake phrases still allow an exact pause command")
        expect(VoiceCommand.parse("Hey assistant, I'll handle it") == .handoff, "Natural handoff wording is recognized")
        expect(VoiceCommand.parse("Hey assistant, ready to continue") == .resume, "Natural resume wording is recognized")
        expect(VoiceCommand.parse("Hey assistant, add another requirement") == .supplement, "Natural supplement wording is recognized")
        expect(VoiceCommand.parse("I have one more thing to add") == nil, "Non-command supplemental prose is preserved as task text")
        expect(VoiceCommand.parse("I'll take over") == .handoff, "Handoff is a local command")
        expect(VoiceCommand.parse("Continue the task") == .resume, "Resume is a local command")
        expect(VoiceCommand.parse("Don't pause") == nil, "Negated commands are not intercepted")
        expect(VoiceCommand.parse("Open WhatsApp then pause") == nil, "A task sentence is not a control command")
        expect(VoiceCommand.parse("Supplement") == .supplement, "Supplement starts the pause-first input flow")
        expect(voiceRoute() == .start, "An idle voice task starts directly")
        expect(voiceRoute(current: true, engineRunning: true) == .queue, "A spoken task during active execution is queued")
        expect(voiceRoute(current: true) == .queue, "A spoken task during a paused task is queued")
        expect(voiceRoute(pending: 1) == .queue, "A spoken task joins an existing queue")
        func callRoute(current: Bool = false, pending: Int = 0, engineRunning: Bool = false, releasing: Bool = false) -> VoiceTaskRequestRoute {
            VoiceTaskRequestRouter.route(hasCurrentTask: current, pendingTaskCount: pending, queueRunning: false,
                                         engineRunning: engineRunning, queueSwitching: false, engineReleasing: releasing,
                                         voicePending: false, manualBusy: false, calibrating: false, supersede: true)
        }
        expect(callRoute(current: true, pending: 2) == .start, "A call request starts now instead of joining the queue")
        expect(callRoute(engineRunning: true) == .busy && callRoute(releasing: true) == .busy, "A call request waits for the old run to stop")
        expect(VoiceCommand.parse("Go to the chat with مهند لورييل and type \"Hi, I'm Sam's assistant.\"") == nil, "A follow-up with an Arabic name is task text")
        expect(voiceRoute(current: true, pending: 1, queueRunning: true, engineRunning: true) == .queue,
               "A spoken task joins a queue while it is running")
        expect(voiceRoute(current: true, switching: true) == .busy, "Task switching blocks voice queue changes")
        expect(voiceRoute(current: true, releasing: true) == .busy, "Input release blocks voice queue changes")
        expect(voiceRoute(voicePending: true) == .busy, "Voice preparation blocks duplicate requests")
        expect(voiceRoute(manualBusy: true) == .busy, "Manual input blocks voice queue changes")
        expect(voiceRoute(current: true, calibrating: true) == .busy, "Calibration blocks voice queue changes")
        expect(voiceRoute(queueRunning: true) == .busy, "An inconsistent active queue cannot start a second task")
        var oldTask = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        oldTask.removeValue(forKey: "amendments")
        let oldRecord = try JSONDecoder().decode(PhoneTaskRecord.self, from: JSONSerialization.data(withJSONObject: oldTask))
        expect(oldRecord.effectiveGoal == oldRecord.goal, "Older history has no implicit supplemental instructions")

        let actionCount = ModelProbe.gestures.count
        engine.start(task: "Open a page", settings: settings)
        try await waitUntil { engine.phase == .observing }
        let taskID = engine.currentRecord?.id, step = engine.currentStep
        do { try engine.amendTask("  "); preconditionFailure("Empty supplement was accepted") } catch {}
        expect(engine.running, "An invalid supplement cannot interrupt the task")
        try engine.amendTask("Only inspect; do not send anything")
        expect(engine.phase == .paused && !engine.running, "Supplement cancels the old plan and waits for Continue")
        expect(engine.currentRecord?.id == taskID && engine.currentStep == step, "Supplement preserves task identity and progress")
        expect(engine.currentRecord?.goal == "Open a page", "Original goal remains visible")
        expect(engine.currentRecord?.amendments?.count == 1, "Supplement is recorded once")
        try await waitUntil { !engine.releasing }
        expect(ModelProbe.gestures.count == actionCount, "The interrupted model response cannot execute")
        let supplemented = engine.currentRecord!
        store.upsert(supplemented)
        expect(TaskHistoryStore(url: path).records.first?.effectiveGoal == supplemented.effectiveGoal, "Supplement survives history reload")
        ModelProbe.delay = 0; ModelProbe.reply = "THINK: nothing to send\nDO: done New requirements verified"
        engine.resume()
        try await waitUntil { engine.phase == .completed && !engine.releasing }
        expect(ModelProbe.prompts.last?.contains("Only inspect; do not send anything") == true, "The next model observation receives the new instructions")
        do { try engine.amendTask("Too late"); preconditionFailure("Completed task was amended") } catch {}
        expect(engine.currentRecord?.amendments?.count == 1, "A completed task rejects amendments")

        ModelProbe.delay = 1_000_000_000
        engine.start(task: "Human takeover", settings: settings)
        try await waitUntil { engine.phase == .observing }
        engine.handoff()
        expect(engine.phase == .needsUser && !engine.running && engine.pendingAction == nil, "User takeover discards the pending plan")
        try await waitUntil { !engine.releasing }
        expect(engine.canResume, "Takeover retains a resumable task")
        expect(ModelProbe.gestures.count == actionCount, "Takeover prevents the old action")
        engine.stop(); try await waitUntil { !engine.releasing }
        expect(!engine.hasCurrentTask, "Stop removes resume eligibility even after handoff")
        checks += ContextChecks.run()
        print("\(checks) product-state checks passed. No network, phone or BLE actions.")
    }
}
