import Foundation
import Combine

// Each recording is a directory transaction: metadata and closed audio commit
// together via a same-volume Pending -> Items rename. No global index can lose it.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var records: [LocalRecording] = []
    @Published private(set) var pending: [PendingRecording] = []
    @Published private(set) var problems: [RecordingProblem] = []
    @Published private(set) var trashCount = 0
    @Published private(set) var error = ""
    @Published private(set) var audioBytes = 0
    private let root: URL
    private let fm = FileManager.default
    init(folder: URL? = nil) {
        root = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneAgentRecordings", isDirectory: true)
        reload()
    }
    private func directory(_ section: String, id: UUID? = nil) -> URL {
        let base = root.appendingPathComponent(section, isDirectory: true)
        return id.map { base.appendingPathComponent($0.uuidString, isDirectory: true) } ?? base
    }
    private func folderIsSafe(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw AgentError.message("Recording library folder is invalid; stopped") }
    }
    private func protect(_ url: URL) throws {
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var value = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try value.setResourceValues(flags)
    }
    private func prepare() throws {
        for folder in [root, directory("Items"), directory("Pending"), directory("Trash")] {
            if !fm.fileExists(atPath: folder.path) { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try folderIsSafe(folder); try protect(folder)
        }
    }
    private func regularSize(_ url: URL, limit: Int) throws -> Int {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let n = v.fileSize, n >= 0, n <= limit else { throw AgentError.message("Recording file is missing, invalid, or over the size limit") }
        return n
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL, limit: Int = 100_000) throws -> T {
        _ = try regularSize(url, limit: limit)
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch { throw AgentError.message("Recording transcript is corrupted; audio was not overwritten") }
    }
    private func write<T: Encodable>(_ value: T, at url: URL, limit: Int = 100_000) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw AgentError.message("Recording transcript is too large") }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try protect(url)
    }
    private func folders(_ section: String) throws -> [(UUID, URL)] {
        let files = try fm.contentsOfDirectory(at: directory(section), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        guard files.count <= 200 else { throw AgentError.message("Unexpected number of items in the recording library; check the files first") }
        return try files.map { url in
            guard let id = UUID(uuidString: url.lastPathComponent), id.uuidString == url.lastPathComponent else { throw AgentError.message("Unknown file in the recording library; nothing was written") }
            try folderIsSafe(url); return (id, url)
        }
    }
    func reload() {
        do {
            try prepare()
            var loaded: [LocalRecording] = [], drafts: [PendingRecording] = [], bad: [RecordingProblem] = []; var total = 0
            for section in ["Items", "Pending", "Trash"] {
                let dirs = try folders(section)
                if section == "Trash" { trashCount = dirs.count }
                for (id, folder) in dirs {
                    let audio = folder.appendingPathComponent("audio.m4a")
                    if fm.fileExists(atPath: audio.path) { total += try regularSize(audio, limit: LocalRecording.maxTotalBytes) }
                    guard section != "Trash" else { continue }
                    do {
                        if section == "Items" {
                            let record = try read(LocalRecording.self, at: folder.appendingPathComponent("record.json")); try record.validate()
                            guard record.id == id, try regularSize(audio, limit: LocalRecording.maxAudioBytes) > 0 else { throw AgentError.message("Recording file is invalid") }
                            loaded.append(record)
                        } else {
                            let draft = try read(PendingRecording.self, at: folder.appendingPathComponent("pending.json"))
                            guard draft.id == id, !draft.title.isEmpty, draft.title.count <= 80, draft.createdAt.timeIntervalSince1970.isFinite else { throw AgentError.message("Unfinished recording info is invalid") }
                            drafts.append(draft)
                        }
                    } catch { bad.append(.init(id: id, pending: section == "Pending")) }
                }
            }
            guard loaded.count + drafts.count + bad.count <= 100, total <= LocalRecording.maxTotalBytes else { throw AgentError.message("Recording library is full; export or delete items first") }
            records = loaded.sorted { $0.createdAt > $1.createdAt }; pending = drafts.sorted { $0.createdAt > $1.createdAt }; problems = bad
            audioBytes = total; error = bad.isEmpty ? "" : "\(bad.count) item(s) couldn't be read; you can review, export the audio, or delete them. Nothing was overwritten"
        } catch { self.error = "Couldn't fully read the recording library; nothing was written. Check storage space or file permissions" }
    }
    func makePending(title: String) throws -> PendingRecording {
        reload(); guard error.isEmpty else { throw AgentError.message(error) }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, records.count + pending.count < 100,
              audioBytes + (pending.count + 1) * LocalRecording.maxAudioBytes <= LocalRecording.maxTotalBytes else { throw AgentError.message("Title must be 1–80 characters; the library holds up to 100 items / 300 MB. Export or delete items first") }
        let value = PendingRecording(id: UUID(), title: title, createdAt: Date())
        let target = directory("Pending", id: value.id)
        try fm.createDirectory(at: target, withIntermediateDirectories: false); try protect(target)
        try write(value, at: target.appendingPathComponent("pending.json"))
        try Data().write(to: target.appendingPathComponent("audio.m4a")); try protect(target.appendingPathComponent("audio.m4a"))
        pending.insert(value, at: 0); return value
    }
    func audioURL(_ id: UUID, pending isPending: Bool = false) throws -> URL {
        try prepare(); let folder = directory(isPending ? "Pending" : "Items", id: id); try folderIsSafe(folder)
        let url = folder.appendingPathComponent("audio.m4a"); _ = try regularSize(url, limit: LocalRecording.maxAudioBytes); return url
    }
    func finalize(_ id: UUID, duration: TimeInterval, interrupted: Bool) throws -> LocalRecording {
        let folder = directory("Pending", id: id); try folderIsSafe(folder)
        let draft = try read(PendingRecording.self, at: folder.appendingPathComponent("pending.json"))
        guard draft.id == id, try regularSize(try audioURL(id, pending: true), limit: LocalRecording.maxAudioBytes) > 0 else { throw AgentError.message("Recording has no valid audio; not saved as a complete record") }
        // Reapply attributes after the recorder has closed or recreated its file.
        try protect(folder.appendingPathComponent("audio.m4a"))
        let record = LocalRecording(id: id, title: draft.title, createdAt: draft.createdAt, updatedAt: Date(), duration: duration, interrupted: interrupted)
        try record.validate(); try write(record, at: folder.appendingPathComponent("record.json"))
        try fm.moveItem(at: folder, to: directory("Items", id: id))
        records.insert(record, at: 0); pending.removeAll { $0.id == id }; reload(); return record
    }
    func importAudio(_ data: Data, title: String, duration: Double) throws -> LocalRecording {
        guard !data.isEmpty, data.count <= LocalRecording.maxAudioBytes,
              duration.isFinite, duration > 0, duration <= LocalRecording.maxDuration else { throw AgentError.message("Imported audio exceeds the size or duration limit") }
        let draft = try makePending(title: title)
        do {
            let target = try audioURL(draft.id, pending: true)
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return try finalize(draft.id, duration: duration, interrupted: false)
        } catch {
            // Remove only this operation's uncommitted directory, never an item.
            try? fm.removeItem(at: directory("Pending", id: draft.id)); reload()
            throw error
        }
    }
    func saveText(_ id: UUID, text: String, origin: RecordingTextOrigin) throws {
        guard text.count <= 12000 else { throw AgentError.message("Text exceeds 12,000 characters; it was not truncated or saved") }
        var record = try currentForUpdate(id)
        record.transcript = text; record.textOrigin = text.isEmpty ? .none : origin; record.updatedAt = Date(); try record.validate()
        let folder = directory("Items", id: id); try folderIsSafe(folder); try write(record, at: folder.appendingPathComponent("record.json"))
        records[records.firstIndex(where: { $0.id == id })!] = record
    }
    func rename(_ id: UUID, title: String) throws {
        var record = try currentForUpdate(id)
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines); record.updatedAt = Date(); try record.validate()
        let folder = directory("Items", id: id); try folderIsSafe(folder); try write(record, at: folder.appendingPathComponent("record.json"))
        records[records.firstIndex(where: { $0.id == id })!] = record
    }
    private func currentForUpdate(_ id: UUID) throws -> LocalRecording {
        guard let previous = records.first(where: { $0.id == id }) else { throw AgentError.message("The record changed; select it again") }
        reload()
        guard error.isEmpty, let current = records.first(where: { $0.id == id }), current == previous else {
            throw AgentError.message("The library or record changed; text was not overwritten. Reload and review")
        }
        return current
    }
    func speakerDocument(_ id: UUID) throws -> SpeakerDocument? {
        let record = try currentForUpdate(id)
        let url = directory("Items", id: id).appendingPathComponent("speakers.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        let value = try read(SpeakerDocument.self, at: url, limit: 500_000); try value.validate()
        guard value.recordingID == id, value.duration == record.duration,
              value.audioSHA256 == SpeakerDocument.digest(try Data(contentsOf: audioURL(id))) else { throw AgentError.message("Saved segments don't match the current audio; the original audio and on-device transcript are unchanged") }
        return value
    }
    func saveSpeakerDocument(_ value: SpeakerDocument) throws {
        try value.validate(); let record = try currentForUpdate(value.recordingID)
        guard record.duration == value.duration, value.audioSHA256 == SpeakerDocument.digest(try Data(contentsOf: audioURL(record.id))) else { throw AgentError.message("The recording changed; segments were not saved") }
        let url = directory("Items", id: record.id).appendingPathComponent("speakers.json")
        if fm.fileExists(atPath: url.path) { _ = try regularSize(url, limit: 500_000) }
        try write(value, at: url, limit: 500_000)
    }
    func removeSpeakerDocument(_ id: UUID) throws {
        _ = try currentForUpdate(id)
        let url = directory("Items", id: id).appendingPathComponent("speakers.json")
        if fm.fileExists(atPath: url.path) { _ = try regularSize(url, limit: 500_000); try fm.removeItem(at: url) }
    }
    func remove(_ id: UUID, pending isPending: Bool = false) throws {
        try prepare(); let folder = directory(isPending ? "Pending" : "Items", id: id); try folderIsSafe(folder)
        let trash = directory("Trash", id: id)
        guard !fm.fileExists(atPath: trash.path) else { throw AgentError.message("Clear audio pending deletion first") }
        try fm.moveItem(at: folder, to: trash)
        records.removeAll { $0.id == id }; pending.removeAll { $0.id == id }; problems.removeAll { $0.id == id }
        do { try fm.removeItem(at: trash); reload() }
        catch { reload(); throw AgentError.message("The record was removed from the list, but audio cleanup failed; tap Clear Pending Audio to retry") }
    }
    func clearTrash() throws {
        try prepare()
        for (_, folder) in try folders("Trash") { try fm.removeItem(at: folder) }
        reload()
    }
}
