// Offline environment for the production AgentEngine and FastAgent. No phone, model or BLE calls.
import Foundation
import CoreGraphics

struct ScreenFrame {
    let capturedAt = Date(), fullDisplay = true
}
@MainActor final class CaptureService {
    var running = true
    var frame: ScreenFrame? { running ? ScreenFrame() : nil }
}
@MainActor final class OfflineBLE {
    var ready = true
    var releases = 0
    func release() async { releases += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
}
@MainActor final class MouseExecutor {
    let ble = OfflineBLE()
    func validateCalibration(frame: ScreenFrame?) throws -> PointerCalibration {
        guard ble.ready else { throw AgentError.message("offline disconnect") }
        return PointerCalibration(screenWidth: 402, screenHeight: 874, gainX: 1, gainY: 1, originX: 0, originY: 0,
                                  validationError: 1, peripheralID: "offline", createdAt: Date(timeIntervalSince1970: 1))
    }
}
enum SettingsStore { static func apiKey(for endpoint: String? = nil) -> String { "offline-placeholder" } }
enum ModelEndpointPolicy { static func url(_ endpoint: String) throws -> URL { URL(string: endpoint)! } }

/// The app is always in the background: the run never holds for its own UI.
final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.background
}

/// What the offline model replies and which gestures reached the phone.
@MainActor enum ModelProbe {
    static var calls = 0
    static var prompts: [String] = []
    static var delay: UInt64 = 0
    static var reply = "THINK: offline\nDO: done offline result"
    static var gestures: [String] = []
    static var gestureDelay: UInt64 = 0
}

/// The configured model: the brief gets a fixed reply, the actor `ModelProbe.reply`.
@MainActor final class BrainLLM: ChatModel {
    let model = "offline-model"
    init(settings: AgentSettings, apiKey: String) {}
    static func isTimeout(_ error: Error) -> Bool { false }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        if system == BrainBrief.system { return ChatResult(text: #"{"intent": "offline brief"}"#, total: 0) }
        ModelProbe.calls += 1; ModelProbe.prompts.append(text)
        if ModelProbe.delay > 0 { try await Task.sleep(nanoseconds: ModelProbe.delay) }
        return ChatResult(text: ModelProbe.reply, total: 0)
    }
}

/// A screen that is always live and quiet, so looks and settles return at once.
@MainActor final class BrainScreen: ScreenSource {
    let capture: CaptureService
    init(capture: CaptureService) { self.capture = capture }
    var live: Bool { capture.running }
    var frame: Data? { capture.running ? Data([0xFF, 0xD8, 0xFF]) : nil }
    var updated: Double { brainNow() - 1 }
    var capturedAt: Double { brainNow() }
    var confirmedAt: Double { brainNow() + 1 }
    var aspect: Double { 9 / 19.5 }
    func afterAction(since: Double) async {}
}

@MainActor final class BrainDevice: HIDDevice {
    weak var screen: BrainScreen?
    var tapAt: ((Double, Double) async throws -> Void)?
    init(executor: MouseExecutor) {}
    var links = 0
    var connected = true
    func send(_ command: String) async throws -> String { "ok" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
}

/// Records each gesture by name; `gestureDelay` keeps one in flight.
@MainActor final class BrainPointer: Gestures {
    let device: HIDDevice
    init(device: HIDDevice, calibrationFile: URL, screen: ScreenSource? = nil) { self.device = device }
    func beginRun() {}
    func adopt(_ c: PointerCalibration) {}
    private func record(_ name: String) async throws {
        ModelProbe.gestures.append(name)
        if ModelProbe.gestureDelay > 0 { try await Task.sleep(nanoseconds: ModelProbe.gestureDelay) }
    }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { try await record("tap") }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { try await record("swipe") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { try await record("drag") }
    func type(_ text: String) async throws { try await record("type") }
    func key(_ combo: String) async throws { try await record("key") }
    func goHome() async throws { try await record("home") }
    func goBack() async throws { try await record("back") }
    func reset() async throws {}
}

@MainActor func leaveApp(_ pointer: BrainPointer) async -> Bool { true }
@MainActor func holdWhileInFront(pointer: BrainPointer, lastActed: Double, running: Bool, capture: BrainScreen,
                                 resumedAt: Double, onHold: () -> Void) async throws {}
extension FastPaths {
    @MainActor static func openApp(_ open: Opening, pointer: Gestures, screen: BrainScreen, since: Double,
                                   check: () throws -> Void) async throws -> Bool { false }
}
