import Foundation
import Speech
import AVFoundation
import Vision
import ImageIO
import PDFKit

enum LocalFileRecognition {
    static func imageText(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]; request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in observation.topCandidates(1).first.map { ($0.confidence < 0.4 ? "[uncertain] " : "") + $0.string } }.joined(separator: "\n")
    }
    static func imageText(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width)*Double(height) <= 20_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw AgentError.message("Image is invalid or over 20 megapixels")
        }
        return try imageText(image)
    }
    static func scannedPage(_ page: PDFPage) throws -> String {
        guard let reference = page.pageRef else { throw AgentError.message("PDF page can't be rendered") }
        let box = reference.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw AgentError.message("PDF page size is invalid") }
        let scale = 1600 / max(box.width, box.height), width = max(1, Int(box.width*scale)), height = max(1, Int(box.height*scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AgentError.message("Couldn't prepare the PDF page for recognition") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(reference.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw AgentError.message("Couldn't prepare the PDF page") }
        return try imageText(image)
    }
    @MainActor
    static func audioText(_ url: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw AgentError.message("On-device transcription isn't available on this device; no audio was uploaded") }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0, Double(file.length)/file.processingFormat.sampleRate <= 600 else { throw AgentError.message("Audio files can be up to 10 minutes; split it first") }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await installation.downloadAndInstall() }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var expired = false
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            expired = true; await analyzer.cancelAndFinishNow()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            let results = Task { () throws -> String in
                var segments: [String] = [], end = -1.0, count = 0
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let next = result.range.end.seconds
                    guard result.isFinal, next > end else { continue }; end = next
                    let text = String(result.text.characters); count += text.count + (segments.isEmpty ? 0 : 1)
                    guard count <= 12000 else { throw AgentError.message("Transcript exceeds 12,000 characters; split the audio first. No truncated result was saved") }
                    segments.append(text)
                }
                let text = segments.joined(separator: " ")
                guard !text.isEmpty else { throw AgentError.message("No speech was recognized in the audio file") }; return text
            }
            do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true); let text = try await results.value; try Task.checkCancellation(); guard !expired else { throw AgentError.message("File transcription timed out; no partial result was saved. Shorten the audio") }; return text }
            catch { results.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
}
