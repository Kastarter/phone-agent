import Foundation
import Combine

/// Self-test links for scripts/device-run.sh: phoneagent://run?task=<text>[&id=<runId>] starts a task like the
/// composer's Start (debug builds only), phoneagent://stop stops it. Each run that reaches a terminal state, or
/// that couldn't start, appends one JSON line to Documents/device-runs.jsonl.
extension PhoneAgentViewModel {
    /// Returns true when the link was a self-test link (other phoneagent:// links are handled elsewhere).
    @discardableResult
    func handleDeviceRunURL(_ url: URL) -> Bool {
        guard url.scheme == "phoneagent" else { return false }
        switch url.host {
        case "stop":
            stop(); return true
        case "run":
            #if DEBUG
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let task = items.first { $0.name == "task" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = items.first { $0.name == "id" }?.value.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
                ?? UUID().uuidString
            Task { await startDeviceRun(task, id: id) }
            #endif
            return true
        default:
            return false
        }
    }

    #if DEBUG
    private func startDeviceRun(_ task: String, id: String) async {
        let recorder = DeviceRunRecorder.shared
        recorder.finish(outcome: "superseded", summary: "Another device run started", steps: engine.currentStep)
        let started = Date()
        func refuse(_ reason: String) {
            recorder.append(DeviceRunResult(id: id, goal: task, outcome: "not_started", seconds: 0, steps: 0,
                                            summary: reason, started: started, ended: Date()))
        }
        guard !task.isEmpty else { return refuse("The link has no task text") }
        guard !engine.running, !queueRunning, !queueSwitching, taskQueue.pendingCount == 0 else {
            return refuse("Busy: a task is running or queued")
        }
        // A leftover paused/failed task would make Start queue the new one; a test run replaces it instead.
        if engine.hasCurrentTask {
            engine.stop()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !engine.executionSettled, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard engine.executionSettled else { return refuse("The previous task is still finishing") }
        }
        notice = ""; taskPlan = []; goal = task
        startAgent()
        guard engine.running, let record = engine.currentRecord else {
            let reason = [notice, engine.error].first { !$0.isEmpty }
                ?? (showPrivacyConsent ? "AI data consent is needed" : showPreparation
                    ? "Not ready: start full-screen sharing, connect and calibrate the mouse, and set up a model" : "The task didn't start")
            return refuse(reason)
        }
        recorder.watch(id: id, goal: task, recordID: record.id, started: started, engine: engine)
    }
    #endif
}

struct DeviceRunResult: Codable {
    var id: String, goal: String, outcome: String
    var seconds: Double, steps: Int
    var summary: String
    var started: Date, ended: Date
}

/// Follows one device run on the engine's published record and writes its result once.
@MainActor final class DeviceRunRecorder {
    static let shared = DeviceRunRecorder()
    private var run: (id: String, goal: String, recordID: UUID, started: Date)?
    private var observer: AnyCancellable?
    private weak var engine: AgentEngine?
    private static let terminal: Set<TaskOutcome> = [.completed, .failed, .needsUser, .stopped, .interrupted, .preview]

    static var file: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("device-runs.jsonl")
    }

    func watch(id: String, goal: String, recordID: UUID, started: Date, engine: AgentEngine) {
        run = (id, goal, recordID, started); self.engine = engine
        // @Published fires before the value is stored; the record passed in is the new one.
        observer = engine.$currentRecord.sink { [weak self, weak engine] record in
            guard let self, let run = self.run else { return }
            let steps = engine?.currentStep ?? 0
            guard let record, record.id == run.recordID else {
                return self.finish(outcome: "stopped", summary: record == nil ? "Task discarded" : "Replaced by another task", steps: steps)
            }
            if Self.terminal.contains(record.outcome) {
                self.finish(outcome: record.outcome.rawValue, summary: record.summary, steps: steps)
            }
        }
    }

    func finish(outcome: String, summary: String, steps: Int) {
        guard let run else { return }
        self.run = nil; observer?.cancel(); observer = nil
        let ended = Date()
        append(DeviceRunResult(id: run.id, goal: run.goal, outcome: outcome,
                               seconds: (ended.timeIntervalSince(run.started) * 10).rounded() / 10, steps: steps,
                               summary: String(summary.prefix(400)), started: run.started, ended: ended))
    }

    func append(_ result: DeviceRunResult) {
        guard let file = Self.file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(result) else { return }
        data.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: file) else { try? data.write(to: file, options: .atomic); return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
}
