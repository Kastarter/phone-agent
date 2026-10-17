// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import Combine
import UIKit

/// CaptureService frames as the fast agent sees them: about 480 px wide, JPEG 0.75. Idle confirmations
/// (same pixels, newer confirmedAt) never count as a new frame, so `settled()` can see a quiet screen.
@MainActor final class BrainScreen: ScreenSource {
    let capture: CaptureService
    private(set) var updated = 0.0
    private(set) var confirmedAt = 0.0
    private var lastCaptured: Date?
    private var cached: (Date, Data)?
    private var subscription: AnyCancellable?

    init(capture: CaptureService) {
        self.capture = capture
        subscription = capture.$frame.sink { [weak self] frame in self?.receive(frame) }
    }

    private func receive(_ frame: ScreenFrame?) {
        guard let frame else { return }
        if frame.capturedAt != lastCaptured { lastCaptured = frame.capturedAt; updated = brainNow() }
        confirmedAt = frame.confirmedAt.timeIntervalSince1970
    }

    var live: Bool { capture.running && capture.frame?.fullDisplay == true }
    var capturedAt: Double { capture.frame?.capturedAt.timeIntervalSince1970 ?? 0 }
    var aspect: Double {
        guard let f = capture.frame, f.sourceHeight > 0 else { return 9 / 19.5 }
        return Double(f.sourceWidth) / Double(f.sourceHeight)
    }

    /// The capture's own full-resolution JPEG, for reading small text (Home Screen labels) with Vision.
    var fullJPEG: Data? { capture.frame?.jpeg }

    var frame: Data? {
        guard let f = capture.frame else { return nil }
        if let cached, cached.0 == f.capturedAt { return cached.1 }
        let size = f.image.size
        guard size.width > 0, size.height > 0 else { return f.jpeg }
        let target = CGSize(width: 480, height: (480 * size.height / size.width).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            f.image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.75) else { return f.jpeg }
        cached = (f.capturedAt, jpeg)
        return jpeg
    }

    /// Wait until the screen changes (then until it settles) or 0.6 s pass without a change; at least 0.15 s.
    func afterAction(since: Double) async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        let deadline = since + 0.6
        // A newer pixel frame, or an idle confirmation that the screen did not change.
        while capturedAt <= since && confirmedAt <= since + 0.25 && brainNow() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        if capturedAt > since { await settled(quiet: 0.4, least: 0, most: 2.5) }
    }
}
