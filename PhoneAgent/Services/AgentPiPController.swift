import SwiftUI
import AVKit
import AVFoundation
import CoreMedia
import Combine

// A silent, locally rendered live status stream. It reads task status only,
// without reading screenshot pixels or credential stores. No private PiP APIs.
private final class PiPPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
final class AgentPiPController: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var starting = false
    @Published private(set) var automaticOnExit = false
    @Published private(set) var error = ""
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private weak var engine: AgentEngine?
    private let stopTask: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var observation: NSKeyValueObservation?
    private var startTimeout: Task<Void, Never>?
    private var pixelBuffer: CVPixelBuffer?
    private var signature = ""
    private var appearance: ColorScheme = .dark
    private nonisolated let playbackState = PiPPlaybackState()
    private var paused: Bool {
        get { playbackState.paused }
        set { playbackState.paused = newValue }
    }
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var audioActive = false
    private var wantsStart = false
    private var attached = false
    private var suppressedUntilForeground = false
    private var interrupted: NSObjectProtocol?
    static let restoreTask = Notification.Name("PhoneAgent.restoreTaskFromPiP")

    init(engine: AgentEngine, stopTask: @escaping () -> Void) {
        self.engine = engine; self.stopTask = stopTask
        super.init()
        displayLayer.videoGravity = .resizeAspect
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        receiver = synchronizer.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            error = "This device does not support Picture in Picture"; return
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        // Background auto-start is opt-in; the setting arms a visible inline source.
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
        observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in
                guard let self else { return }
                self.possible = change.newValue ?? false
                self.startIfReady()
            }
        }
        engine.objectWillChange.sink { [weak self] _ in
            // ObservableObject publishes before mutation; read the committed state next.
            Task { @MainActor in self?.renderAndEnqueue() }
        }.store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.enabled else { return }
            self.renderAndEnqueue()
        }.store(in: &subscriptions)
        interrupted = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.audioActive else { return }
                self.audioActive = false
                self.stopTask(); self.error = "Picture in Picture was interrupted by the system and the task stopped. Return to the app to start again."
                self.paused = true; self.controller?.invalidatePlaybackState()
            }
        }
    }
    deinit { if let interrupted { NotificationCenter.default.removeObserver(interrupted) } }
    func setAutomaticOnExit(_ value: Bool) {
        guard automaticOnExit != value else { return }
        automaticOnExit = value; suppressedUntilForeground = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = value
        if value, UIApplication.shared.applicationState == .active {
            _ = preparePreview(clearError: true)
        } else if !value && !active && !starting {
            enabled = false; startTimeout?.cancel(); releaseAudio()
        }
    }
    func applicationBecameActive() {
        guard automaticOnExit else { return }
        suppressedUntilForeground = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        if !active && !starting { _ = preparePreview() }
    }
    func applicationEnteredBackground() {
        guard automaticOnExit, !suppressedUntilForeground, enabled, !active, !starting else { return }
        // AVKit owns the actual transition. Do not call start() for every inactive
        // phase: alerts, Control Center and the capture picker also cause inactivity.
        // Bound cleanup if the system declines automatic PiP.
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, !self.active,
                  UIApplication.shared.applicationState == .background else { return }
            self.enabled = false; self.starting = false; self.wantsStart = false
            self.error = "Could not start Picture in Picture automatically. Check the system PiP setting, or return to the app and open the overlay manually."
            self.releaseAudio()
        }
    }
    private func preparePreview(clearError: Bool = false) -> Bool {
        enabled = true
        guard controller != nil else { error = "This device does not support Picture in Picture"; return false }
        if clearError { error = "" }
        paused = false
        if !audioActive {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                audioActive = true
            } catch {
                self.error = "Could not prepare Picture in Picture: \(error.localizedDescription)"; return false
            }
            receiver?.flush()
            synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        renderAndEnqueue(); controller?.invalidatePlaybackState()
        return true
    }
    func open() {
        guard preparePreview(clearError: true) else { return }
        suppressedUntilForeground = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = automaticOnExit
        if active { return }
        wantsStart = true; starting = true
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.starting else { return }
            self.wantsStart = false; self.starting = false
            self.error = "Picture in Picture is not allowed yet. Keep the app in the foreground and tap \"Open Overlay\", or check Settings → General → Picture in Picture."
            self.releaseAudio()
        }
        startIfReady()
    }
    func close() {
        suppressedUntilForeground = true
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        wantsStart = false; starting = false; startTimeout?.cancel()
        if active { controller?.stopPictureInPicture() }
        else { enabled = false; releaseAudio() }
    }
    func suspendForVoice() async throws {
        close()
        let deadline = Date().addingTimeInterval(3)
        while active && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !active else { throw AgentError.message("Close the action overlay before starting voice") }
        enabled = false; releaseAudio()
    }
    func attach() { guard !attached else { return }; attached = true; renderAndEnqueue(); startIfReady() }
    func detach() { attached = false }
    func setAppearance(_ value: ColorScheme) {
        guard appearance != value else { return }
        appearance = value
        signature = ""
        renderAndEnqueue()
    }
    private func startIfReady() {
        guard wantsStart, attached, possible, let controller, !active else { return }
        wantsStart = false
        controller.startPictureInPicture()
    }
    private func releaseAudio() {
        synchronizer.setRate(0, time: .invalid)
        guard audioActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioActive = false
    }
    private func renderAndEnqueue() {
        guard enabled, let engine else { return }
        if engine.running && paused { paused = false; controller?.invalidatePlaybackState() }
        let action = engine.executingAction ?? engine.pendingAction
        let title = action?.label ?? engine.state
        let detail = !engine.error.isEmpty ? engine.error : (action?.reason ?? "Last step: \(engine.logs.last?.title ?? "Waiting for task to start")")
        let next = "\(engine.currentStep)|\(engine.running)|\(title)|\(detail)|\(engine.state)|\(paused)"
        if next != signature || pixelBuffer == nil {
            signature = next
            pixelBuffer = render(step: engine.currentStep, running: engine.running, title: title,
                                 detail: detail, state: engine.state, failed: !engine.error.isEmpty)
        }
        guard let pixelBuffer else { return }

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        guard let receiver else { return }
        switch receiver.enqueueImmediately(ready) {
        case .cancelledDueToFlushRequiredToResume: receiver.flush()
        case .cancelledDueToError(let error):
            self.error = "Overlay update failed: \(error.localizedDescription)"
        default: break
        }
    }
    private func render(step: Int, running: Bool, title: String, detail: String, state: String, failed: Bool) -> CVPixelBuffer? {
        let width = 640, height = 360
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
        let traits = UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)
        UIColor.systemBackground.resolvedColor(with: traits).setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let accent = UIColor.label.resolvedColor(with: traits)
        let muted = UIColor.secondaryLabel.resolvedColor(with: traits)
        func text(_ value: String, rect: CGRect, font: UIFont, color: UIColor) {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.lineSpacing = 4
            (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style], context: nil)
        }
        text("✦ Phone Agent · Action Overlay", rect: CGRect(x: 30, y: 24, width: 500, height: 34), font: .systemFont(ofSize: 25, weight: .semibold), color: accent)
        (failed ? UIColor.systemRed : (running ? UIColor.systemGreen : muted)).setFill()
        UIBezierPath(ovalIn: CGRect(x: 597, y: 35, width: 12, height: 12)).fill()
        text(step > 0 ? "Step \(step)" : "Ready", rect: CGRect(x: 30, y: 79, width: 570, height: 32), font: .systemFont(ofSize: 24, weight: .medium), color: muted)
        text(title, rect: CGRect(x: 30, y: 120, width: 580, height: 89), font: .systemFont(ofSize: 34, weight: .semibold), color: accent)
        text(detail, rect: CGRect(x: 30, y: 215, width: 580, height: 68), font: .systemFont(ofSize: 23), color: failed ? .systemRed : muted)
        text(paused ? "Task stopped · Return to the app to restart" : state,
             rect: CGRect(x: 30, y: 308, width: 580, height: 30), font: .systemFont(ofSize: 20), color: accent)
        return buffer
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.active = true; self.starting = false; self.startTimeout?.cancel()
            guard self.enabled else { self.controller?.stopPictureInPicture(); return }
            self.error = ""
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.active = false; self.enabled = false; self.starting = false; self.wantsStart = false
            self.startTimeout?.cancel(); self.releaseAudio()
            // Restore/return can stop PiP after scene activation. Re-arm inline
            // without immediately reopening a window; an explicit close waits
            // for the next foreground visit instead.
            if self.automaticOnExit, !self.suppressedUntilForeground,
               UIApplication.shared.applicationState == .active { _ = self.preparePreview() }
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.starting = false; self.wantsStart = false; self.startTimeout?.cancel()
            self.error = "Picture in Picture failed to start: \(error.localizedDescription)"; self.releaseAudio()
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.restoreTask, object: nil)
            completionHandler(true)
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            self.paused = !playing
            if !playing { self.stopTask() }
            // Play resumes the status monitor only. It never restarts a stopped task.
            self.renderAndEnqueue(); self.controller?.invalidatePlaybackState()
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { playbackState.paused }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) { completion() }
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }

}

private final class PiPSourceView: UIView {
    weak var controller: AgentPiPController?
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        controller?.displayLayer.frame = bounds
        CATransaction.commit()
        if window != nil && bounds.width > 0 && bounds.height > 0 { controller?.attach() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { controller?.detach() } else { setNeedsLayout() }
    }
}
struct AgentPiPSource: UIViewRepresentable {
    let controller: AgentPiPController
    @Environment(\.colorScheme) private var colorScheme
    func makeUIView(context: Context) -> UIView {
        let view = PiPSourceView(); view.controller = controller
        view.backgroundColor = .systemBackground
        view.layer.addSublayer(controller.displayLayer)
        view.layer.cornerRadius = 12; view.clipsToBounds = true
        view.isAccessibilityElement = true; view.accessibilityLabel = "Phone Agent live action PiP preview"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { controller.setAppearance(colorScheme) }
}
struct AgentPiPButton: View {
    @ObservedObject var controller: AgentPiPController
    var body: some View {
        Button { controller.enabled ? controller.close() : controller.open() } label: {
            Image(systemName: controller.enabled ? "pip.exit" : "pip.enter").font(.system(size: 18))
                .frame(width: 44, height: 44).agentGlass(in: Circle(), interactive: true)
        }.buttonStyle(.plain).accessibilityLabel(controller.enabled ? "Close action overlay" : "Open action PiP")
    }
}
struct AgentPiPPanel: View {
    @ObservedObject var controller: AgentPiPController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
        if controller.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AgentPiPSource(controller: controller).frame(width: 88, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.active ? "Action overlay on" : (controller.automaticOnExit ? "Shows when you leave" : "Action preview"))
                            .font(.caption.weight(.medium))
                        Button(controller.starting ? "Opening…" : (controller.active ? "Close Overlay" : "Open Overlay")) {
                            if controller.active { controller.close() } else { controller.open() }
                        }.font(.caption).disabled(controller.starting)
                    }
                    Spacer(minLength: 0)
                    Button { controller.close() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Close overlay and preview")
                }
                if !controller.error.isEmpty { AgentNotice(text: controller.error, error: true) }
            }.padding(12).agentGlass(in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 16).padding(.bottom, 8)
                .transition(.opacity)
        }
        }.animation(reduceMotion ? nil : .smooth(duration: 0.3), value: controller.enabled)
    }
}
