import Foundation
import CoreGraphics
import ImageIO
import Vision

struct ScreenElement: Equatable {
    let id: String
    let text: String
    /// Normalized 0..1, top-left origin.
    let box: CGRect
    var center: CGPoint

    init(id: String, text: String, box: CGRect) {
        self.id = id
        self.text = text
        self.box = box
        center = CGPoint(x: box.midX, y: box.midY)
    }
}

enum ScreenReaderError: LocalizedError {
    case decodeFailed
    var errorDescription: String? { "The screen image could not be decoded." }
}

enum ScreenReader {
    static let maxElements = 220

    /// Locates on-screen text with Apple Vision (Home Screen labels and search results for FastPaths).
    static func elements(jpeg: Data, fast: Bool = true) async throws -> [ScreenElement] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenReaderError.decodeFailed }
        return try await Task.detached(priority: .userInitiated) { try recognize(image, fast: fast) }.value
    }

    private static func recognize(_ image: CGImage, fast: Bool) throws -> [ScreenElement] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        // Arabic exists only at .accurate; listing it first keeps English intact and finds Arabic labels.
        let languages = ["ar-SA", "en-US"].filter { supported.contains($0) }
        request.recognitionLanguages = languages.isEmpty ? ["en-US"] : languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var found: [(text: String, box: CGRect)] = []
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            guard text.count > 1 || text.first?.isNumber == true else { continue }
            guard let box = topLeftBox(observation.boundingBox) else { continue }
            found.append((text, box))
        }
        if found.count > maxElements {
            func weight(_ box: CGRect) -> Double {
                let d = hypot(box.midX - 0.5, box.midY - 0.5) / 0.7072
                return Double(box.width * box.height) * (1.25 - d)
            }
            found = Array(found.sorted { weight($0.box) > weight($1.box) }.prefix(maxElements))
        }
        // Group into visual rows (centers within half a line height), then left to right.
        var rows: [[(text: String, box: CGRect)]] = []
        for item in found.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - item.box.midY) <= min(last.box.height, item.box.height) / 2 {
                rows[rows.count - 1].append(item)
            } else { rows.append([item]) }
        }
        found = rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
        return found.enumerated().map { ScreenElement(id: "e\($0.offset)", text: $0.element.text, box: $0.element.box) }
    }

    /// Vision boxes are normalized with a bottom-left origin; clamps to the image and flips to top-left.
    static func topLeftBox(_ b: CGRect) -> CGRect? {
        let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !box.isNull && box.width > 0 && box.height > 0 ? box : nil
    }
}
