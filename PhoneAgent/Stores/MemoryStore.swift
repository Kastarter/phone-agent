import Foundation
import Combine
import NaturalLanguage
import UIKit

enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case note, preference, screen, transcript, document
    var id: String { rawValue }
    // Raw values are persisted to on-disk memory files, so they must not change.
    var displayName: String {
        switch self {
        case .note: return "Note"
        case .preference: return "Preference"
        case .screen: return "Screen"
        case .transcript: return "Transcript"
        case .document: return "Document"
        }
    }
}
struct AssistantMemory: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var kind: MemoryKind = .note
    var source = "Manual entry"
    var createdAt = Date()
    var updatedAt = Date()
    var enabled = true
    var imageName: String? = nil
}
struct MemoryHit: Identifiable, Sendable {
    var memory: AssistantMemory
    var score: Double
    var id: UUID { memory.id }
}
struct MemorySearchResult: Sendable {
    var hits: [MemoryHit]
    var semantic: Bool
}

// All indexing stays on device. Missing sentence models fall back to word search.
actor MemoryIndex {
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private struct Cached { var updated: Date; var language: NLLanguage; var vector: [Double] }
    private var vectors: [UUID: Cached] = [:]
    private struct Words { var updated: Date; var tokens: Set<String> }
    private var wordCache: [UUID: Words] = [:]
    private func tokens(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text.lowercased()
        var result = Set<String>()
        let normalized = tokenizer.string!
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            if let string = tokenizer.string { let word = String(string[range]); if !["a", "an", "the", "to", "and", "for"].contains(word) { result.insert(word) } }; return true
        }
        return result
    }
    func search(_ query: String, records: [AssistantMemory], limit: Int) -> MemorySearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return MemorySearchResult(hits: records.prefix(limit).map { MemoryHit(memory: $0, score: 1) }, semantic: false) }
        let language = NLLanguageRecognizer.dominantLanguage(for: query) ?? .simplifiedChinese
        let embedding = embeddings[language] ?? NLEmbedding.sentenceEmbedding(for: language)
        if let embedding { embeddings[language] = embedding }
        let qvector = embedding?.vector(for: String(query.prefix(600)))
        let qtokens = tokens(query)
        let ids = Set(records.map(\.id)); vectors = vectors.filter { ids.contains($0.key) }; wordCache = wordCache.filter { ids.contains($0.key) }
        var hits: [MemoryHit] = []
        for record in records {
            if Task.isCancelled { return MemorySearchResult(hits: [], semantic: qvector != nil) }
            let content = record.title + " " + record.text
            let exact = content.localizedCaseInsensitiveContains(query)
            let words: Set<String>
            if let cached = wordCache[record.id], cached.updated == record.updatedAt { words = cached.tokens }
            else { words = tokens(content); wordCache[record.id] = Words(updated: record.updatedAt, tokens: words) }
            let lexical = Double(qtokens.intersection(words).count) / Double(max(1, qtokens.count))
            var similarity = 0.0
            if let embedding, let qvector {
                let vector: [Double]?
                if let cache = vectors[record.id], cache.updated == record.updatedAt, cache.language == language { vector = cache.vector }
                else {
                    vector = embedding.vector(for: String(content.prefix(600)))
                    if let vector { vectors[record.id] = Cached(updated: record.updatedAt, language: language, vector: vector) }
                }
                if let vector, vector.count == qvector.count {
                    let dot = zip(vector, qvector).reduce(0.0) { $0 + $1.0 * $1.1 }
                    let denominator = sqrt(vector.reduce(0) { $0 + $1 * $1 } * qvector.reduce(0) { $0 + $1 * $1 })
                    if denominator > 0 { similarity = dot / denominator }
                }
            }
            guard exact || lexical >= 0.35 || similarity > 0.60 else { continue }
            hits.append(MemoryHit(memory: record, score: (exact ? 2 : 0) + lexical + max(0, similarity)))
        }
        hits.sort { $0.score == $1.score ? $0.memory.updatedAt > $1.memory.updatedAt : $0.score > $1.score }
        return MemorySearchResult(hits: Array(hits.prefix(limit)), semantic: qvector != nil)
    }
}

@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var records: [AssistantMemory] = []
    @Published private(set) var error = ""
    private let folder: URL
    private let index = MemoryIndex()
    private var readable = true
    private var url: URL { folder.appendingPathComponent("memories.json") }
    private struct Document: Codable { var version = 1; var records: [AssistantMemory] }
    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/Memories", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 12_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            guard data.count < 12_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1, doc.records.count <= 200, Set(doc.records.map(\.id)).count == doc.records.count,
                  doc.records.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 120 && !$0.text.isEmpty && $0.text.count <= 12000 }) else { throw CocoaError(.fileReadCorruptFile) }
            records = doc.records.sorted { $0.updatedAt > $1.updatedAt }
        } catch { readable = false; self.error = "The memory file cannot be read right now; the original file is kept. Export it first, or clear and rebuild." }
    }
    func save(_ value: AssistantMemory, image: UIImage? = nil) throws {
        guard readable else { throw AgentError.message(error) }
        var value = value
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(value.title.count), (1...12000).contains(value.text.count) else { throw AgentError.message("Title must be 1–120 characters and content 1–12,000 characters") }
        let old = records.first { $0.id == value.id }
        guard old != nil || records.count < 200 else { throw AgentError.message("Memory holds up to 200 items. Delete ones you no longer need first.") }
        value.updatedAt = Date(); value.source = String(value.source.prefix(160))
        try prepareFolder()
        var newImage: URL?
        if let image {
            guard let jpeg = image.jpegData(compressionQuality: 0.75), jpeg.count <= 3_000_000 else { throw AgentError.message("The image is too large. Save text only.") }
            let name = UUID().uuidString + ".jpg"; let target = folder.appendingPathComponent(name)
            try protectedWrite(jpeg, to: target); value.imageName = name; newImage = target
        }
        var updated = records.filter { $0.id != value.id }; updated.insert(value, at: 0)
        do { try persist(updated) }
        catch { if let newImage { try? FileManager.default.removeItem(at: newImage) }; throw error }
        records = updated; error = ""
        if let oldName = old?.imageName, oldName != value.imageName, let oldURL = imageURL(oldName) { try? FileManager.default.removeItem(at: oldURL) }
    }
    func remove(_ id: UUID) throws {
        guard readable else { throw AgentError.message(error) }
        let old = records.first { $0.id == id }; let updated = records.filter { $0.id != id }
        try persist(updated); records = updated
        if let name = old?.imageName, let target = imageURL(name) { try? FileManager.default.removeItem(at: target) }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        records = []; readable = true; error = ""
    }
    func exportText() throws -> Data {
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 12_000_000 else { throw AgentError.message("The memory file is too large. Connect to a computer to keep the original file.") }
            return try Data(contentsOf: url)
        }
        return try JSONEncoder().encode(Document(records: records))
    }
    private func excerpt(_ text: String, query: String) -> String {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = query
        var words: [String] = []
        tokenizer.enumerateTokens(in: query.startIndex..<query.endIndex) { range, _ in let word = String(query[range]); if word.count > 1 { words.append(word) }; return true }
        let match = text.range(of: query, options: .caseInsensitive) ?? words.sorted(by: { $0.count > $1.count }).compactMap { text.range(of: $0, options: .caseInsensitive) }.first
        let location = match.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        let start = text.index(text.startIndex, offsetBy: max(0, location - 400))
        let content = String(text[start...].prefix(1200))
        return (start == text.startIndex ? "" : "…") + content + (text.distance(from: start, to: text.endIndex) > 1200 ? "…" : "")
    }
    func image(for record: AssistantMemory) -> UIImage? {
        guard let name = record.imageName, let target = imageURL(name), let data = try? Data(contentsOf: target) else { return nil }
        return UIImage(data: data)
    }
    func search(_ query: String, limit: Int = 30, enabledOnly: Bool = false) async -> MemorySearchResult {
        let source = records.filter { !enabledOnly || $0.enabled }
        var result = await index.search(String(query.prefix(4000)), records: source, limit: max(1, min(200, limit)))
        result.hits = result.hits.filter { hit in records.contains { $0.id == hit.id && $0.updatedAt == hit.memory.updatedAt && (!enabledOnly || $0.enabled) } }
        return result
    }
    func context(for query: String) async -> String {
        let result = await search(query, limit: 3, enabledOnly: true)
        var selected = result.hits.map(\.memory)
        if let preference = records.first(where: { $0.kind == .preference && $0.enabled }), !selected.contains(where: { $0.id == preference.id }) { selected.insert(preference, at: 0) }
        let items = selected.prefix(3).map { ["title": $0.title, "content": excerpt($0.text, query: query), "source": $0.source,
            "updated_at": ISO8601DateFormatter().string(from: $0.updatedAt)] }
        guard !items.isEmpty, let data = try? JSONSerialization.data(withJSONObject: items), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
    private func imageURL(_ name: String) -> URL? {
        guard name.hasSuffix(".jpg"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        return folder.appendingPathComponent(name)
    }
    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = folder; try excluded.setResourceValues(values)
    }
    private func persist(_ items: [AssistantMemory]) throws { try prepareFolder(); try protectedWrite(JSONEncoder().encode(Document(records: items)), to: url) }
    private func protectedWrite(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
