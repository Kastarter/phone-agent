import Foundation

// Only compressed samples are retained. This is not a recording or an upload
// queue; stopping sampling clears it, and frames are never written to disk.
struct CameraObservationFrame {
    let jpeg: Data
    let capturedAt: Date
    let capturedUptime: TimeInterval
    let width: Int
    let height: Int
}

struct CameraObservationWindow {
    static let duration: TimeInterval = 12
    static let sampleLimit = 24
    static let requestLimit = 8
    static let frameBytes = 262_144
    private(set) var frames: [CameraObservationFrame] = []
    mutating func clear() { frames = [] }
    mutating func append(_ frame: CameraObservationFrame, now: TimeInterval) {
        guard now.isFinite, frame.capturedUptime.isFinite, frame.capturedUptime <= now,
              now - frame.capturedUptime <= Self.duration, frame.capturedAt.timeIntervalSinceReferenceDate.isFinite, !frame.jpeg.isEmpty,
              frame.jpeg.count <= Self.frameBytes, (1...640).contains(frame.width), (1...640).contains(frame.height) else { return }
        if let last = frames.last {
            if last.width != frame.width || last.height != frame.height { clear() }
            else if frame.capturedUptime <= last.capturedUptime { return }
        }
        frames.removeAll { now - $0.capturedUptime > Self.duration }
        frames.append(frame)
        if frames.count > Self.sampleLimit { frames.removeFirst(frames.count - Self.sampleLimit) }
    }
    func selected(now: TimeInterval) -> [CameraObservationFrame] {
        guard now.isFinite else { return [] }
        let source = frames.filter { $0.capturedUptime <= now && now - $0.capturedUptime <= Self.duration }
        guard source.count > Self.requestLimit else { return source }
        // Preserve the first and last samples and distribute the others across
        // the window; selecting the newest eight would discard earlier motion.
        return (0..<Self.requestLimit).map {
            source[Int((Double($0) * Double(source.count - 1) / Double(Self.requestLimit - 1)).rounded())]
        }
    }
    static func content(question: String, frames: [CameraObservationFrame], now: TimeInterval) throws -> [[String: Any]] {
        guard now.isFinite, (2...requestLimit).contains(frames.count), let first = frames.first, let last = frames.last,
              last.capturedUptime <= now, now - last.capturedUptime <= 2,
              now - first.capturedUptime <= duration else { throw AgentError.message("The camera sequence needs 2–8 new frames; please wait a moment and try again") }
        var previous = -Double.infinity
        let formatter = ISO8601DateFormatter()
        var content: [[String: Any]] = [["type": "text", "text": "User question: \(question)\nBelow are \(frames.count) sampled camera frames in capture order. No continuous video or audio is provided; changes between frames may not have been captured, so distinguish visible facts, changes, and uncertainty."]]
        for (index, frame) in frames.enumerated() {
            guard frame.capturedUptime.isFinite, frame.capturedAt.timeIntervalSinceReferenceDate.isFinite, frame.capturedUptime > previous, !frame.jpeg.isEmpty,
                  frame.jpeg.count <= frameBytes, frame.width == first.width, frame.height == first.height,
                  (1...640).contains(frame.width), (1...640).contains(frame.height) else { throw AgentError.message("The camera sequence order, size, or capacity is invalid and was not sent") }
            previous = frame.capturedUptime
            let offset = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), frame.capturedUptime - first.capturedUptime)
            content.append(["type": "text", "text": "Sample \(index + 1) · +\(offset)s · \(formatter.string(from: frame.capturedAt))"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + frame.jpeg.base64EncodedString(), "detail": "low"]])
        }
        return content
    }
}
