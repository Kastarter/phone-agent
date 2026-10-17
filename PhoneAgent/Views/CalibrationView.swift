import SwiftUI
import UIKit

/// A probe click whose tap never reached the calibration surface (most likely the AssistiveTouch button).
private struct ProbeTimeout: Error {}

@MainActor
final class CalibrationModel: ObservableObject {
    @Published var text = "\(CalibrationSolver.probeSteps)-step automatic measurement. Once started, do not touch the screen and keep it in portrait."
    @Published var busy = false
    @Published var finished = false
    @Published var error = ""
    @Published var markers: [CGPoint] = []
    @Published var target: CGPoint?
    @Published var latestPoint: CGPoint?
    @Published var completedSteps = 0
    @Published var summary = ""
    private var waiter: CheckedContinuation<CGPoint, Error>?
    private var waiterToken: UUID?
    private var waitTimeout: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var diagnosticLines: [String] = []
    let executor: MouseExecutor
    var size = CGSize.zero
    var onSaved: (() -> Void)?
    init(executor: MouseExecutor) { self.executor = executor }
    private func record(_ message: String) {
        diagnosticLines.append("\(Date().ISO8601Format()) \(message)")
        let file = URL.documentsDirectory.appendingPathComponent("calibration-diagnostics.log")
        try? diagnosticLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    private func finishWait(_ token: UUID, result: Result<CGPoint, Error>) {
        guard waiterToken == token, let continuation = waiter else { return }
        waiter = nil; waiterToken = nil; waitTimeout?.cancel(); waitTimeout = nil
        continuation.resume(with: result)
    }
    func receive(_ point: CGPoint) {
        guard let token = waiterToken else { return }
        latestPoint = point; markers.append(point)
        finishWait(token, result: .success(point))
    }
    func cancel() {
        guard busy else { return }
        session = UUID(); task?.cancel()
        if let token = waiterToken { finishWait(token, result: .failure(CancellationError())) }
        text = "Ending calibration…"
        // The owned task releases input before clearing the shared busy flag.
    }
    private func waitPoint() async throws -> CGPoint {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiter = continuation; waiterToken = token
                waitTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    self?.finishWait(token, result: .failure(ProbeTimeout()))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWait(token, result: .failure(CancellationError()))
            }
        }
    }
    /// Home, move by (ux, uy) units, click, and catch the tap; nil when no tap arrived in time.
    private func probe(_ ux: Int, _ uy: Int) async throws -> CGPoint? {
        try await executor.homePointer()
        try await executor.movePositionUnits(x: ux, y: uy)
        // The board reports completion after the last report, so only a short settle is needed.
        try await executor.sleep(0.06)
        async let point = waitPoint()
        try await executor.sleep(0.03)
        try await executor.click()
        do { return try await point } catch is ProbeTimeout { return nil }
    }
    private func checkSession(_ token: UUID, screen: CGSize, connection: UUID, device: String) throws {
        try Task.checkCancellation()
        guard token == session else { throw CancellationError() }
        guard executor.ble.ready, executor.ble.selectedID == device,
              executor.ble.pointerConnectionGeneration == connection else {
            throw AgentError.message("Mouse connection changed. Please recalibrate.")
        }
        guard abs(size.width - screen.width) < 1, abs(size.height - screen.height) < 1 else {
            throw AgentError.message("The screen rotated during calibration. Return to portrait and try again.")
        }
    }
    private func checkPoint(_ point: CGPoint, screen: CGSize) throws {
        guard point.x.isFinite, point.y.isFinite,
              point.x > 12, point.x < screen.width - 12,
              point.y > 12, point.y < screen.height - 12 else {
            throw AgentError.message("The calibration point hit the screen edge and could not be measured. Lower the AssistiveTouch tracking speed; if Snap to Item is on, turn it off and try again.")
        }
    }
    private static let verificationFailure = "Verification failed: the check click must land within 8 pt and the fit RMS must be ≤6 pt. If Snap to Item is on, turn it off and retry; keep portrait and a fixed tracking speed. Diagnostics saved."
    // Probe procedure adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan (TouchCalibration.swift).
    /// Touch-probe calibration: about 8 clicks, a straight line per axis, no LLM.
    func start() {
        guard !busy, !executor.calibrationInProgress else { return }
        guard executor.ble.bufferedMotionReady else {
            error = "Connect a board running the updated constant-speed firmware, then start calibration."; return
        }
        guard executor.ble.ready, size.width > 0, size.height > size.width,
              let device = executor.ble.selectedID else {
            error = "Connect the AssistiveTouch mouse first and keep the screen in portrait."; return
        }
        let screen = size, connection = executor.ble.pointerConnectionGeneration
        let W = Double(screen.width), H = Double(screen.height)
        let token = UUID(); session = token
        executor.calibrationInProgress = true
        busy = true; finished = false; error = ""; markers = []; target = nil; latestPoint = nil
        completedSteps = 0; summary = ""; diagnosticLines = []
        record("Probe calibration version=\(CalibrationSolver.probeVersion) motionProfile=\(PointerMotion.profileVersion) screen=\(screen.width)x\(screen.height)")
        task = Task {
            do {
                // (units from home, landed fraction) per axis
                var xs: [(Double, Double)] = [], ys: [(Double, Double)] = []
                @MainActor func click(_ ux: Int, _ uy: Int, aim: CGPoint?, label: String) async throws -> CGPoint? {
                    text = "Calibration \(completedSteps + 1)/\(max(CalibrationSolver.probeSteps, completedSteps + 1)): \(label)"
                    target = aim.map { CGPoint(x: $0.x * screen.width, y: $0.y * screen.height) }; latestPoint = nil
                    let point = try await probe(ux, uy)
                    try checkSession(token, screen: screen, connection: connection, device: device)
                    completedSteps += 1
                    record("Probe units=(\(ux),\(uy)) landed=\(point.map { "(\($0.x),\($0.y))" } ?? "none")")
                    return point.map { CGPoint(x: $0.x / screen.width, y: $0.y / screen.height) }
                }
                func keep(_ ux: Int, _ uy: Int, _ f: CGPoint) {
                    if ProbeFit.usable(Double(f.x)) { xs.append((Double(ux), Double(f.x))) }
                    if ProbeFit.usable(Double(f.y)) { ys.append((Double(uy), Double(f.y))) }
                }
                // Stage 1: a rough line through home per axis, then a 2-point line across the middle.
                guard let first = try await click(60, 60, aim: nil, label: "rough movement") else {
                    throw AgentError.message("No calibration tap received. Check that the AssistiveTouch left button is mapped to Single-Tap.")
                }
                try checkPoint(CGPoint(x: first.x * screen.width, y: first.y * screen.height), screen: screen)
                keep(60, 60, first)
                guard var roughX = ProbeFit.throughHome((60, Double(first.x))), var roughY = ProbeFit.throughHome((60, Double(first.y))) else {
                    throw AgentError.message("Base movement is unstable. Fix the pointer speed, keep portrait, and try again.")
                }
                let mx = roughX.units(for: 0.55), my = roughY.units(for: 0.55)
                if let mid = try await click(mx, my, aim: CGPoint(x: 0.55, y: 0.55), label: "rough movement") {
                    keep(mx, my, mid)
                    roughX = ProbeFit.line([(60, Double(first.x)), (Double(mx), Double(mid.x))]) ?? roughX
                    roughY = ProbeFit.line([(60, Double(first.y)), (Double(my), Double(mid.y))]) ?? roughY
                }
                let base = (xs, ys)
                var lines: (ProbeFit.Line, ProbeFit.Line)?
                var err = Double.infinity, rms = Double.infinity
                for round in 0..<2 {
                    if round == 1 { (xs, ys) = base; record("Verification missed; repeating the target clicks once") }
                    let (lx, ly) = lines ?? (roughX, roughY)
                    // Stage 2: corners and centre; a missed click most likely hit the AssistiveTouch button.
                    for f in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.25, y: 0.75),
                              CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.5, y: 0.5)] {
                        let ux = lx.units(for: Double(f.x)), uy = ly.units(for: Double(f.y))
                        guard ux > 0, uy > 0 else { continue }
                        if let p = try await click(ux, uy, aim: f, label: "target") { keep(ux, uy, p); continue }
                        AssistiveTouchSpots.remember(x: Double(f.x), y: Double(f.y))
                        await executor.ble.release()
                        if executor.ble.keyboardReady { try? await executor.pressCombo(0, 41) }  // close its menu
                        let r = CGPoint(x: f.x + (0.5 - f.x) * 0.4, y: f.y + (0.5 - f.y) * 0.4)
                        let vx = lx.units(for: Double(r.x)), vy = ly.units(for: Double(r.y))
                        if let p = try await click(vx, vy, aim: r, label: "target, closer to the centre") { keep(vx, vy, p) }
                        else { AssistiveTouchSpots.remember(x: Double(r.x), y: Double(r.y)); await executor.ble.release() }
                    }
                    guard xs.count >= CalibrationSolver.probeMinimumFitSamples, ys.count >= CalibrationSolver.probeMinimumFitSamples,
                          let fx = ProbeFit.line(xs), let fy = ProbeFit.line(ys) else {
                        throw AgentError.message("Too few calibration taps arrived. Move the AssistiveTouch button to a screen edge, lower the tracking speed, and turn off Snap to Item if it's on.")
                    }
                    lines = (fx, fy)
                    rms = hypot(fx.rms * W, fy.rms * H)
                    record("Fit x=\(fx.a)u+\(fx.b) y=\(fy.a)u+\(fy.b) samples=\(xs.count)/\(ys.count) rms=\(rms)")
                    // Stage 3: one check click, placed with the new fit.
                    let check = CGPoint(x: 0.5, y: 0.62)
                    if let p = try await click(fx.units(for: Double(check.x)), fy.units(for: Double(check.y)), aim: check, label: "check") {
                        err = hypot(Double(p.x - check.x) * W, Double(p.y - check.y) * H)
                    } else { err = .infinity }
                    summary = String(format: "Check error %.1f pt · fit RMS %.1f pt", err, rms)
                    record("Check error=\(err) rms=\(rms)")
                    if err <= CalibrationSolver.maxValidationError && rms <= CalibrationSolver.maxValidationRMS { break }
                }
                guard let (fx, fy) = lines, err <= CalibrationSolver.maxValidationError, rms <= CalibrationSolver.maxValidationRMS else {
                    throw AgentError.message(Self.verificationFailure)
                }
                try checkSession(token, screen: screen, connection: connection, device: device)
                let final = PointerCalibration(screenWidth: W, screenHeight: H,
                    gainX: fx.a * W, gainY: fy.a * H, originX: fx.b * W, originY: fy.b * H,
                    validationError: err, peripheralID: device, createdAt: Date(), movementVersion: PointerMotion.profileVersion,
                    calibrationVersion: CalibrationSolver.probeVersion,
                    fitSampleCount: min(xs.count, ys.count), validationSampleCount: 1, validationRMS: rms, returnDrift: err)
                guard final.usable else { throw AgentError.message("Calibration parameters failed the integrity check. Please try again.") }
                executor.calibration = final; SettingsStore.saveCalibration(final)
                record("Calibration saved")
                text = "\(CalibrationSolver.probeSteps)-step calibration complete"; finished = true; onSaved?()
            } catch is CancellationError {
                if !finished { text = "Calibration cancelled" }
            } catch {
                if token == session {
                    self.error = error.localizedDescription; record("Failed: \(self.error)"); text = "Calibration failed"
                }
            }
            if let pending = waiterToken { finishWait(pending, result: .failure(CancellationError())) }
            waitTimeout?.cancel(); target = nil
            // A cancelled task cannot send release through BLETransport. Use a new task.
            await Task { @MainActor in await executor.ble.release() }.value
            executor.calibrationInProgress = false
            busy = false; task = nil
        }
    }
}

struct CalibrationView: View {
    @StateObject var model: CalibrationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The step after a saved calibration: learn the keyboards for typing.
    @State private var keyboardCheck = false
    var body: some View {
        if keyboardCheck { KeyboardCheckView(model: .init(executor: model.executor)) } else { calibration }
    }
    private var calibration: some View {
        ZStack {
            CalibrationSurface(target: model.target, latestPoint: model.latestPoint, markers: model.markers,
                onPoint: { model.receive($0) }, onSize: { model.size = $0 }).ignoresSafeArea()
            if model.busy {
                VStack {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.text).font(.caption.weight(.medium))
                            ProgressView(value: Double(model.completedSteps), total: Double(max(CalibrationSolver.probeSteps, model.completedSteps)))
                        }.padding(12).background(AgentPalette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false).accessibilityHidden(true)
                        Button("Cancel") { model.cancel(); dismiss() }
                            .font(.subheadline.weight(.medium)).padding(12)
                            .agentGlass(in: Capsule(), interactive: true).buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8)
            } else {
                VStack {
                    Spacer()
                    VStack(spacing: 13) {
                        HStack(spacing: 10) {
                            AgentOrb(size: 35)
                            Text("\(CalibrationSolver.probeSteps)-Step Precision Calibration").font(.title3.weight(.semibold))
                        }
                        Text(model.text).font(.subheadline).multilineTextAlignment(.center)
                        if !model.summary.isEmpty { Text(model.summary).font(.footnote.monospacedDigit()).multilineTextAlignment(.center) }
                        if !model.error.isEmpty { AgentNotice(text: model.error, error: true) }
                        Text("2 rough clicks · 5 targets · 1 check, in a few seconds\nEvery click returns to the top-left corner, then moves diagonally.\nSnap to Item can shift where taps land on real pages; turn it off before calibrating if you need precise coordinates.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 10) {
                                Button(model.finished ? "Recalibrate" : "Start Calibration") { model.start() }.buttonStyle(AgentButtonStyle(primary: !model.finished))
                                if model.finished { Button("Check Keyboard") { keyboardCheck = true }.buttonStyle(AgentButtonStyle()) }
                                Button("Done") { model.cancel(); dismiss() }.buttonStyle(AgentButtonStyle(primary: false))
                            }
                        }
                    }.padding(20).frame(maxWidth: 390).agentGlass(in: RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }.tint(AgentPalette.accent).onDisappear { model.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.cancel() } }
    }
}

private struct CalibrationSurface: UIViewRepresentable {
    let target: CGPoint?
    let latestPoint: CGPoint?
    let markers: [CGPoint]
    let onPoint: (CGPoint) -> Void
    let onSize: (CGSize) -> Void
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.backgroundColor = .systemBackground
        // Painted targets do not create individual controls for pointer snapping.
        view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
        view.onPoint = onPoint; view.onSize = onSize; return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.onPoint = onPoint; uiView.onSize = onSize
        uiView.target = target; uiView.latestPoint = latestPoint; uiView.markers = markers; uiView.setNeedsDisplay()
    }
    final class Surface: UIView {
        var target: CGPoint?
        var latestPoint: CGPoint?
        var markers: [CGPoint] = []
        var onPoint: ((CGPoint) -> Void)?
        var onSize: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            if let size = window?.bounds.size {
                DispatchQueue.main.async { [weak self] in self?.onSize?(size) }
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first?.location(in: window) else { return }
            onPoint?(point)
        }
        override func draw(_ rect: CGRect) {
            UIColor.systemGray5.setStroke()
            let grid = UIBezierPath()
            for i in 1..<10 {
                let x = rect.width * CGFloat(i) / 10, y = rect.height * CGFloat(i) / 10
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: rect.height))
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: rect.width, y: y))
            }
            grid.lineWidth = 1; grid.stroke()
            UIColor.systemGray.withAlphaComponent(0.4).setFill()
            for point in markers {
                let p = convert(point, from: window)
                UIBezierPath(ovalIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
            }
            if let target {
                let p = convert(target, from: window)
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
                ring.lineWidth = 2; ring.stroke()
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: p.x - 20, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 20, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 20)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 20))
                cross.lineWidth = 1; cross.stroke()
                if let latestPoint {
                    let actual = convert(latestPoint, from: window)
                    UIColor.systemOrange.setStroke()
                    let line = UIBezierPath(); line.move(to: p); line.addLine(to: actual); line.lineWidth = 1; line.stroke()
                }
            }
            if let latestPoint {
                let p = convert(latestPoint, from: window)
                UIColor.systemOrange.setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
            }
        }
    }
}
