import Foundation
import Combine

enum QueueTaskState: String, Codable {
    case waiting, running, suspended, completed, stopped, preview
    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .suspended: return "Needs your confirmation"
        case .completed: return "Completed"
        case .stopped: return "Stopped"
        case .preview: return "Plan needs review"
        }
    }
}

// Contains configuration, never credentials, screenshots or pending model actions.
struct QueuedPhoneTask: Identifiable, Codable {
    var id: UUID { record.id }
    var record: PhoneTaskRecord
    var settings: AgentSettings
    var step = 0
    var started = false
    var state: QueueTaskState = .waiting
    var note = ""
    var resumable: Bool { ![.completed, .stopped, .preview].contains(state) }
}

@MainActor
final class TaskQueueStore: ObservableObject {
    @Published private(set) var items: [QueuedPhoneTask] = []
    @Published private(set) var error = ""
    private let url: URL
    private var readable = true
    private struct Document: Codable { var version = 1; var items: [QueuedPhoneTask] }
    var pendingCount: Int { items.filter(\.resumable).count }


    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent", isDirectory: true).appendingPathComponent("queue.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let size = try self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
            guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
            try Self.validate(document.items)
            items = document.items.map { item in
                var value = item
                // Execution authority is never restored after a process restart.
                if value.resumable {
                    value.state = .suspended
                    value.note = value.started ? "The last run was interrupted. Check the actual result before continuing." : "After reopening the app, confirm manually to run."
                    if value.started { value.record.outcome = .interrupted }
                }
                return value
            }
        } catch {
            readable = false; self.error = "The task queue could not be read. The original file was kept; you can export it before clearing the queue."
        }
    }
    private static func validate(_ items: [QueuedPhoneTask]) throws {
        guard items.count <= 20, Set(items.map(\.id)).count == items.count else { throw AgentError.message("The queue holds at most 20 items, and task IDs must be unique") }
        for item in items {
            guard !item.record.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.record.effectiveGoal.count <= 12000, item.record.title.count <= 80,
                  item.record.logs.count <= 150, (item.record.amendments ?? []).count <= 20,
                  (0...100).contains(item.step), item.note.count <= 1000,
                  (1...100).contains(item.settings.maxSteps),
                  item.settings.startDelay.isFinite, (0...30).contains(item.settings.startDelay),
                  (256...4096).contains(item.settings.imageMaxSide) else {
                throw AgentError.message("The task queue contains invalid content; the original file was not changed")
            }
        }
    }
    func transaction(_ change: (inout [QueuedPhoneTask]) throws -> Void) throws {
        guard readable else { throw AgentError.message(error) }
        var values = items; try change(&values); try Self.validate(values)
        do {
            let data = try JSONEncoder().encode(Document(items: values))
            guard data.count <= 8_000_000 else { throw AgentError.message("The queue record is too large. Export it and remove finished tasks") }
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var backup = URLResourceValues(); backup.isExcludedFromBackup = true
            var directory = folder; try directory.setResourceValues(backup)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            items = values; error = ""
        } catch {
            self.error = "Queue save failed; the new queue state was not written: " + error.localizedDescription
            throw error
        }
    }
    func update(_ id: UUID, _ change: (inout QueuedPhoneTask) -> Void) throws {
        try transaction { values in
            guard let index = values.firstIndex(where: { $0.id == id }) else { throw AgentError.message("The queued task no longer exists") }
            change(&values[index])
        }
    }
    func append(_ item: QueuedPhoneTask) throws { try transaction { $0.append(item) } }
    func remove(_ id: UUID) throws { try transaction { $0.removeAll { $0.id == id } } }
    func move(_ id: UUID, by offset: Int) throws {
        try transaction { values in
            guard let index = values.firstIndex(where: { $0.id == id }), values[index].state != .running else { return }
            let target = index + offset
            guard values.indices.contains(target), values[target].state != .running else { return }
            values.swapAt(index, target)
        }
    }
    func exportData() throws -> Data {
        if !readable { return try Data(contentsOf: url) }
        return try JSONEncoder().encode(Document(items: items))
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        items = []; readable = true; error = ""
    }
}
