import Foundation

enum RecordingTextOrigin: String, Codable { case none, localRecognition, edited }
struct LocalRecording: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let duration: TimeInterval
    let interrupted: Bool
    var transcript: String = ""
    var textOrigin: RecordingTextOrigin = .none
    static let maxDuration: TimeInterval = 600
    static let maxAudioBytes = 30_000_000
    static let maxRecords = 100
    static let maxTotalBytes = 300_000_000
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 80,
              duration.isFinite, duration > 0, duration <= Self.maxDuration,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
              transcript.count <= 12000, (textOrigin != .none || transcript.isEmpty) else { throw AgentError.message("The recording's title, duration, or text is out of range") }
    }
}
struct PendingRecording: Codable, Identifiable {
    let id: UUID
    let title: String
    let createdAt: Date
}
struct RecordingProblem: Identifiable { let id: UUID; let pending: Bool }
struct RecordingTextSeed { let title: String; let text: String; let source: String }
