import Foundation
import CryptoKit

struct SpeakerSettings: Codable, Equatable {
    var endpoint = "https://api.openai.com/v1/audio/transcriptions"
    var provider = "OpenAI"
    var model = "gpt-4o-transcribe-diarize"
    func validate() throws -> URL {
        guard !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, provider.count <= 80,
              !model.isEmpty, model.count <= 120, model.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }), endpoint.count <= 2048,
              let c = URLComponents(string: endpoint), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.hasSuffix("/audio/transcriptions"),
              c.port == nil || (1...65535).contains(c.port!), let url = c.url else { throw AgentError.message("Enter a standalone HTTPS audio transcription URL (ending in /audio/transcriptions), a provider, and a model that supports diarization; the URL must not contain a key or parameters") }
        return url
    }
    static func validKey(_ key: String) -> Bool { !key.isEmpty && key.count <= 4096 && key.unicodeScalars.allSatisfy { (33...126).contains($0.value) } }
}
struct SpeakerSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var speaker: Int
    var start: Double
    var end: Double
    var text: String
}
struct SpeakerDocument: Codable, Equatable {
    let recordingID: UUID
    let audioSHA256: String
    let duration: Double
    let receivedAt: Date
    let settings: SpeakerSettings
    let serviceText: String
    var speakers: [String]
    var segments: [SpeakerSegment]
    var edited = false
    static let maxFileBytes = 25_000_000
    static func digest(_ audio: Data) -> String { SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined() }
    func validate() throws {
        _ = try settings.validate()
        guard duration.isFinite, duration > 0, duration <= 600, receivedAt.timeIntervalSince1970.isFinite,
              audioSHA256.count == 64, audioSHA256.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }),
              serviceText.count <= 12000, !serviceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !speakers.isEmpty, speakers.count <= 20, Set(speakers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).count == speakers.count,
              speakers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 60 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              !segments.isEmpty, segments.count <= 1200, Set(segments.map(\.id)).count == segments.count,
              segments.reduce(0, { $0 + $1.text.count }) <= 12000 else { throw AgentError.message("The segment labels, text, audio source, or count are out of range and were not saved") }
        var previous = -1.0
        for segment in segments {
            guard speakers.indices.contains(segment.speaker), segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.start < duration, segment.start >= previous, segment.end > segment.start, segment.end <= duration + 0.15,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, segment.text.count <= 4000 else { throw AgentError.message("Segments must be sorted by start time, fall within the recording, and have a valid speaker and text; nothing is trimmed or reordered automatically") }
            previous = segment.start
        }
    }
    static func decode(_ data: Data, recordingID: UUID, audioSHA256: String, duration: Double, settings: SpeakerSettings, date: Date) throws -> SpeakerDocument {
        struct Segment: Decodable { let speaker: String; let start: Double; let end: Double; let text: String }
        struct Envelope: Decodable { let text: String; let segments: [Segment] }
        guard data.count <= 1_000_000, let envelope = try? JSONDecoder().decode(Envelope.self, from: data), !envelope.segments.isEmpty, envelope.segments.count <= 1200 else { throw AgentError.message("The service did not return complete speaker JSON; existing text was not overwritten") }
        var ids: [String] = []; var segments: [SpeakerSegment] = []
        for s in envelope.segments {
            guard !s.speaker.isEmpty, s.speaker.count <= 80, !s.speaker.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AgentError.message("The service returned an invalid speaker label") }
            if !ids.contains(s.speaker) { ids.append(s.speaker) }
            guard ids.count <= 20 else { throw AgentError.message("The service returned more than 20 speakers; nothing was trimmed or saved") }
            segments.append(.init(id: UUID(), speaker: ids.firstIndex(of: s.speaker)!, start: s.start, end: s.end, text: s.text))
        }
        let document = SpeakerDocument(recordingID: recordingID, audioSHA256: audioSHA256, duration: duration, receivedAt: date, settings: settings, serviceText: envelope.text, speakers: ids.indices.map { "Speaker " + String(UnicodeScalar(65 + $0)!) }, segments: segments)
        try document.validate(); return document
    }
    static func time(_ t: Double) -> String { guard t.isFinite, (0...601).contains(t) else { return "Invalid time" }; let seconds = Int(t); return String(format: "%02d:%02d.%01d", seconds / 60, seconds % 60, Int((t - Double(seconds)) * 10)) }
    func referenceText() throws -> String {
        try validate()
        return "Speaker-diarized transcript (verify by listening back; labels do not prove real identity, and manual renaming is only a user annotation)\n" + (edited ? "Includes user edits or removed segments; this is not the service's original verbatim transcript.\n" : "From the service's diarized draft, which may contain attribution or text errors.\n") + segments.map { "[\(Self.time($0.start))–\(Self.time($0.end))] \(speakers[$0.speaker]): \($0.text)" }.joined(separator: "\n")
    }
    func exportText() throws -> String {
        try referenceText() + "\n\nRecipient: \(settings.provider)\nEndpoint: \(settings.endpoint)\nModel: \(settings.model)\nRetrieved at: \(ISO8601DateFormatter().string(from: receivedAt))\nRecording ID: \(recordingID.uuidString)\nAudio SHA256: \(audioSHA256)\nManually edited: \(edited ? "Yes" : "No")\n\nService's original merged text (not updated with manual edits):\n\(serviceText)"
    }
}

struct RecordingPlaybackRange: Equatable {
    let start: Double
    let end: Double
    static func make(start: Double, end: Double?, duration: Double) throws -> Self {
        let end = end ?? duration
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0, duration <= 600,
              start >= 0, start < duration, end > start, end <= duration + 0.15 else { throw AgentError.message("The playback segment time is invalid; check the start and end seconds") }
        return .init(start: start, end: min(end, duration))
    }
}
