// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import CoreGraphics

// What the Fast agent needs from the model, the phone and the screen. The app's adapters (BrainLLM, BrainPointer,
// BrainDevice, BrainScreen) implement them; the offline checks use fakes.

struct ChatResult {
    var text: String
    var firstToken: Double?      // seconds until the first streamed token
    var total: Double
    var finishReason: String?    // "stop", "length" (max tokens hit), …
    var reasoningChars = 0       // reasoning text the model wrote (not part of `text`)
}

/// A chat model the fast agent can ask (BrainLLM, or a fake in tests).
@MainActor protocol ChatModel: AnyObject {
    var model: String { get }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult
}

func brainNow() -> Double { Date().timeIntervalSince1970 }

/// What the fast agent and the pointer need from the screen (BrainScreen, or a fake in tests).
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    /// Local time the last new pixel frame arrived.
    var updated: Double { get }
    var capturedAt: Double { get }
    /// When the capture last confirmed the shown pixels are still current (an idle callback), or 0.
    var confirmedAt: Double { get }
    var aspect: Double { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result.
    func afterAction(since: Double) async
}

extension ScreenSource {
    /// Wait until the screen stops changing: the capture confirms it idle after we began waiting, or no new frame
    /// for `quiet` (plus the last frame's lag).
    func settled(quiet: Double = 0.5, least: Double = 0.15, most: Double = 2.5) async {
        let started = brainNow()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while !idle(since: started) && brainNow() - updated < quiet + lag && brainNow() - started < most {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The capture said "nothing changed" after `since` and after the newest changed frame.
    func idle(since: Double) -> Bool { confirmedAt > since && confirmedAt > capturedAt + 0.05 }

    /// How late the shown frame arrived after it was captured (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since`, or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = brainNow() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if brainNow() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return frame
    }
}

/// What FastAgent does on the phone (BrainPointer, or a fake in tests).
@MainActor protocol Gestures: AnyObject {
    var device: HIDDevice { get }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws
    func drag(_ points: [CGPoint], hold: Bool) async throws
    func type(_ text: String) async throws
    func key(_ combo: String) async throws
    func goHome() async throws
    func goBack() async throws
    func reset() async throws
}

/// What gestures need from the board (BrainDevice, or a fake in tests).
@MainActor protocol HIDDevice: AnyObject {
    /// Bumped on every reconnect: a dropped gesture may have left the button down.
    var links: Int { get }
    var connected: Bool { get }
    @discardableResult func send(_ command: String) async throws -> String
    func waitConnected(_ timeout: TimeInterval) async -> Bool
    /// What the last "type" check found when the text did not show as intended, or nil.
    var typeCheck: String? { get }
}
extension HIDDevice { var typeCheck: String? { nil } }
