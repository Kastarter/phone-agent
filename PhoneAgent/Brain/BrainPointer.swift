// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import CoreGraphics

/// Touch-like gestures on the phone, built from relative mouse moves.
///
/// The pointer is relative, so the app tracks where it is (in mouse units) and moves from there. When the
/// position is unknown, every 20 gestures, or after a big miss it slams the pointer into the screen corner
/// nearest the next target (`home`) to cancel drift; mouse units always count from the top-left corner. Coordinates are fractions of
/// the screen (0..1, origin top-left), so they work for any frame size.
@MainActor final class BrainPointer: Gestures {
    static let rehomeEvery = 20             // gestures between re-homing (sooner after a big miss)
    static let edgePush = 300               // mouse units pushed past the bottom edge to pin the pointer on it
    static let hold = 0.25                  // s to rest before lifting, so iOS adds no momentum
    static let tapGap = 0.15                // s to stay still after a click, so iOS sees a finished tap
    static let nudge = 12                   // mouse units the pointer is wiggled by to find it on screen
    static let aimTolerance = 0.008         // screen fraction; a bigger miss is corrected before pressing
    static let maxMiss = 0.06               // bigger misses are still corrected, but not learned from

    struct Span: Codable, Equatable { var w: Int, h: Int }
    private struct Saved: Codable {
        var w: Int, h: Int, seen: [String: [[Double]]]?, quality: Double?, aspect: Double?, calibratedAt: Date?
    }

    let device: HIDDevice
    weak var screen: ScreenSource?
    private let file: URL
    private(set) var span: Span?  // mouse units needed to cross the full screen width / height
    private var pos: (Int, Int)?  // pointer position in mouse units; nil = unknown
    private var moves = 0
    private var link = 0  // device.links when the pointer was last homed
    /// Axes last homed at the right / bottom edge: landings there are not learned (the fit is from the top-left).
    private var far = (x: false, y: false)
    /// where the pointer really landed (seen on screen) for the fraction we aimed at, per axis; a line fit
    /// through them corrects every later move, so taps get better as the agent works
    private(set) var seen: [String: [(Double, Double)]] = ["x": [], "y": []]
    private(set) var quality: Double?
    private var aspect: Double?
    private var calibratedAt: Date?
    /// The wiggle needs the pointer in the captured frames; after 3 misses in a row a run stops aiming.
    private(set) var aimEnabled = true
    private var notFound = 0

    init(device: HIDDevice, calibrationFile: URL, screen: ScreenSource? = nil) {
        self.device = device
        self.file = calibrationFile
        self.screen = screen
        if let data = try? Data(contentsOf: calibrationFile), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            span = Span(w: saved.w, h: saved.h)
            (quality, aspect, calibratedAt) = (saved.quality, saved.aspect, saved.calibratedAt)
            for axis in ["x", "y"] {
                seen[axis] = (saved.seen?[axis] ?? []).filter { $0.count == 2 }.map { ($0[0], $0[1]) }.suffix(12)
            }
        }
    }

    var calibrated: Bool { span != nil }

    /// A new run: aim again and re-home before the first move.
    func beginRun() { aimEnabled = true; notFound = 0; pos = nil }

    /// Take over the app's saved probe calibration: span = screen / gain, the offset as seed landings.
    func adopt(_ c: PointerCalibration) {
        guard c.createdAt != calibratedAt else { return }
        span = Span(w: Int((c.screenWidth / c.gainX).rounded()), h: Int((c.screenHeight / c.gainY).rounded()))
        seen = ["x": ProbeFit.seed(offset: c.originX / c.screenWidth), "y": ProbeFit.seed(offset: c.originY / c.screenHeight)]
        (quality, aspect, calibratedAt) = (nil, c.screenWidth / c.screenHeight, c.createdAt)
        pos = nil
        save()
    }

    private func remember(_ axis: String, _ sample: (Double, Double)) {
        seen[axis] = Array((seen[axis, default: []] + [sample]).suffix(12))  // deque(maxlen=12)
    }

    /// Calibration plus the observed landings, so the correction survives a restart.
    private func save() {
        guard let span else { return }
        let saved = Saved(w: span.w, h: span.h, seen: seen.mapValues { $0.map { [$0.0, $0.1] } }, quality: quality,
                          aspect: aspect, calibratedAt: calibratedAt)
        try? JSONEncoder().encode(saved).write(to: file)
    }

    func point(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        guard calibrated else { throw DeviceError(message: "pointer not calibrated") }
        try await moveTo(dx(x), dy(y))
        if aim && aimEnabled && screen != nil { try await BrainTrace.time("aim") { try await self.aim(x, y) } }
    }

    /// Closed loop: find the real pointer on screen, fix a miss, and learn the error for later moves.
    private func aim(_ x: Double, _ y: Double) async throws {
        guard let span, let found = try await measure(x, y) else {
            notFound += 1
            if notFound >= 3 { aimEnabled = false }
            return
        }
        notFound = 0
        let fx = Double(found.x), fy = Double(found.y)
        if max(abs(fx - x), abs(fy - y)) <= Self.maxMiss {  // learn from normal drift only, never a stray reading
            if !far.x { remember("x", (fix(x, "x"), fx)) }
            if !far.y { remember("y", (fix(y, "y"), fy)) }
            save()
        } else {
            moves = Self.rehomeEvery  // the position estimate drifted: re-home before the next gesture
        }
        if abs(fx - x) <= Self.aimTolerance && abs(fy - y) <= Self.aimTolerance { return }
        let mx = Int(((x - fx) * Double(span.w)).rounded(.toNearestOrEven)), my = Int(((y - fy) * Double(span.h)).rounded(.toNearestOrEven))
        try await device.send("move \(mx) \(my)")  // fix this miss right away
        if let p = pos { pos = (p.0 + mx, p.1 + my) }
    }

    /// Wiggle the pointer and find it on screen, near the target first, then anywhere.
    private func measure(_ x: Double, _ y: Double) async throws -> CGPoint? {
        guard let screen, let span else { return nil }
        let nudge = x < 0.9 ? Self.nudge : -Self.nudge  // stay clear of the screen edge
        await screen.settled(quiet: 0.15, least: 0.1, most: 0.6)  // pointer at rest
        let before = screen.frame, sent = brainNow()
        try await device.send("move \(nudge) 0")
        var after = await screen.fresh(since: sent, timeout: 1.2)
        if after != nil {
            await screen.settled(quiet: 0.1, least: 0.05, most: 0.4)
            after = screen.frame
        }
        try await device.send("move \(-nudge) 0")
        let shift = Double(nudge) / Double(span.w)
        guard let before, let after else { return nil }
        return FrameVision.pointer(before, after, near: CGPoint(x: x, y: y), shift: shift)
            ?? FrameVision.pointer(before, after, near: CGPoint(x: 0.5, y: 0.5), shift: shift, reach: CGPoint(x: 0.5, y: 0.5))
    }

    /// How far the learned correction has moved targets away from the plain calibration (fraction of the screen).
    var drift: Double {
        [0.2, 0.8].flatMap { t in ["x", "y"].map { abs(fix(t, $0) - t) } }.max() ?? 0
    }

    /// The fraction to aim at so the pointer lands on t, from the line through the observed landings.
    func fix(_ t: Double, _ axis: String) -> Double {
        let pts = seen[axis] ?? []
        guard pts.count >= 2 else { return t }
        let n = Double(pts.count)
        let mc = pts.map(\.0).reduce(0, +) / n, mf = pts.map(\.1).reduce(0, +) / n
        let variance = pts.map { pow($0.0 - mc, 2) }.reduce(0, +)
        var a = variance > 1e-4 ? pts.map { ($0.0 - mc) * ($0.1 - mf) }.reduce(0, +) / variance : 1.0  // landed = a*aimed + b
        a = 0.85 < a && a < 1.15 ? a : 1.0
        let b = mf - a * mc
        return abs(b) < 0.1 ? (t - b) / a : t
    }

    private func moveTo(_ tx: Int, _ ty: Int, rehome: Bool = true) async throws {
        if link != device.links {  // new link: a dropped gesture may have left the button down
            try await device.send("release")
            (pos, link) = (nil, device.links)
        }
        if pos == nil || (rehome && moves >= Self.rehomeEvery) { try await homeNear(tx, ty) }
        let (x, y) = pos!
        pos = nil  // unknown until the move succeeds
        try await BrainTrace.time("move") { try await device.send("move \(tx - x) \(ty - y)") }
        (pos, moves) = ((tx, ty), moves + 1)
    }

    /// Home into the corner nearest the target (units from the top-left), so the move from there is short.
    private func homeNear(_ tx: Int, _ ty: Int) async throws {
        guard let span else { throw DeviceError(message: "pointer not calibrated") }
        let (sx, sy) = PointerCorner.signs(Double(tx) / Double(span.w), Double(ty) / Double(span.h))
        try await BrainTrace.time("home") { try await device.send(PointerCorner.command(sx, sy)) }
        pos = (PointerCorner.origin(sx, edgeFix: fix(1, "x"), span: span.w), PointerCorner.origin(sy, edgeFix: fix(1, "y"), span: span.h))
        (far, moves) = ((sx > 0, sy > 0), 0)
    }

    /// Let go of the button and re-home the pointer, whatever state a gesture left.
    func reset() async throws {
        pos = nil
        try await device.send("release")
        try await device.send("home")
        (pos, moves, far) = ((0, 0), 0, (false, false))
    }

    /// aim: find the pointer on screen first (slower); worth it when a tap just missed.
    func tap(_ x: Double, _ y: Double, aim: Bool = false) async throws {
        try await point(x, y, aim: aim)
        try await device.send("click")
        try await Task.sleep(nanoseconds: UInt64(Self.tapGap * 1e9))
    }

    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool = true) async throws {
        try await drag([CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], hold: hold)
    }

    /// Press at the first point, move through the rest, release: one continuous stroke. hold rests at the end
    /// first, so lists and pickers stop exactly there; system gestures (home, back) need the flick.
    func drag(_ points: [CGPoint], hold: Bool = true) async throws {
        guard let first = points.first else { return }
        try await point(Double(first.x), Double(first.y))
        try await device.send("press")
        do {
            for p in points.dropFirst() {
                try await moveTo(dx(Double(p.x)), dy(Double(p.y)), rehome: false)  // never home mid-drag
            }
            if hold { try await Task.sleep(nanoseconds: UInt64(Self.hold * 1e9)) }
        } catch {
            _ = try? await device.send("release")
            throw error
        }
        try await device.send("release")
    }

    func type(_ text: String) async throws { try await device.send("type \(text)") }
    func key(_ combo: String) async throws { try await device.send("key \(combo)") }
    /// Home key when the firmware has it, else a flick up from the home bar (never Cmd+H: iOS ignores it from the
    /// stick). The pointer's position stays known: the next move goes straight from where the flick ended instead
    /// of re-homing to a corner.
    /// The home flick, which works on the device; the firmware's Home key (AC Home) was ignored by iOS, so it is
    /// only `homeKey()`, a last resort. The pointer is pinned on the bottom edge at mid-width first: the clamp makes
    /// its height exact, so the flick starts on the home bar, and the position stays known for the next move.
    func goHome() async throws {
        try await point(0.5, 0.9)
        try await device.send("move 0 \(Self.edgePush)")
        if let p = pos { pos = (p.0, dy(1)) }
        try await device.send("press")
        do { try await moveTo(dx(0.5), dy(0.45), rehome: false) } catch { _ = try? await device.send("release"); throw error }
        try await device.send("release")
    }
    func homeKey() async throws { try await device.send("homescreen") }
    func goBack() async throws {
        try await swipe(0.015, 0.45, 0.6, 0.45, hold: false)
    }

    private func dx(_ x: Double) -> Int { Int((min(max(fix(x, "x"), 0), 1) * Double(span!.w)).rounded(.toNearestOrEven)) }
    private func dy(_ y: Double) -> Int { Int((min(max(fix(y, "y"), 0), 1) * Double(span!.h)).rounded(.toNearestOrEven)) }
}
