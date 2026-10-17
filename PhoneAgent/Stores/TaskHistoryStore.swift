import Foundation
import Combine

enum TaskOutcome: String, Codable {
    case running, paused, needsUser, completed, failed, stopped, interrupted, preview
    var label: String {
        switch self {
        case .running: return "In Progress"
        case .paused: return "Paused"
        case .needsUser: return "Needs You"
        case .completed: return "Completed"
        case .failed: return "Interrupted"
        case .stopped: return "Stopped"
        case .interrupted: return "Didn't Finish"
        case .preview: return "Plan Ready"
        }
    }
}
struct TaskAmendment: Identifiable, Codable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

struct PhoneTaskRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var goal: String
    var createdAt = Date()
    var updatedAt = Date()
    var outcome: TaskOutcome = .running
    var summary = "Preparing"
    var logs: [AgentLogEntry] = []
    // Optional so existing task files remain readable; older files' subtask lists are ignored.
    var amendments: [TaskAmendment]? = nil
    var effectiveGoal: String {
        let additions = (amendments ?? []).enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        guard !additions.isEmpty else { return goal }
        return goal + "\n\nFollow-up from the user (if it conflicts with the above, the newer explicit request wins):\n" + additions.joined(separator: "\n")
    }
}

@MainActor
final class TaskHistoryStore: ObservableObject {
    @Published private(set) var records: [PhoneTaskRecord] = []
    @Published private(set) var error = ""
    private let url: URL
    private var readable = true
    private struct Document: Codable { var version = 1; var records: [PhoneTaskRecord] }
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent", isDirectory: true).appendingPathComponent("tasks.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
            records = Array(document.records.prefix(50)).map { record in
                var value = record
                if [.running, .paused, .needsUser].contains(value.outcome) {
                    value.outcome = .interrupted
                    value.summary = "The last task didn't finish. Check the phone's current state before deciding whether to run it again."
                }
                return value
            }
        } catch {
            readable = false
            self.error = "History can't be read right now; the original file was kept. You can still run new tasks."
        }
    }
    func upsert(_ record: PhoneTaskRecord) {
        guard readable else { return }
        records.removeAll { $0.id == record.id }; records.insert(record, at: 0)
        records = Array(records.prefix(50)); save()
    }
    func rename(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].title = String(title.prefix(80)); save()
    }
    func remove(_ id: UUID) { records.removeAll { $0.id == id }; save() }
    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records = []; readable = true; error = ""
        } catch { self.error = "Couldn't delete history. Try again later." }
    }
    private func save() {
        guard readable else { return }
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = folder; try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(Document(records: records))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            error = ""
        } catch { self.error = "Couldn't save history. Check your device's free storage." }
    }
}
