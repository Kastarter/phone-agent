import Foundation
import CoreGraphics

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct AgentSettings: Codable {
    var endpoint = "https://openrouter.ai/api/v1/chat/completions"
    var model = "openai/gpt-6-luna"
    var jsonMode = true
    var legacyTokenLimit = false
    var maxSteps = 25
    /// Countdown to swipe home yourself when the app could not leave on its own.
    var startDelay = 5.0
    var previewOnly = false
    var confirmEachStep = false
    var imageMaxSide = 1280
    var providerName: String? = nil
    // Optional so existing saved settings keep their endpoint/key association. Keys of removed settings
    // (decision engine, tools, step interval, Home mapping) are ignored when older settings decode.
    var maxResponseTokens: Int? = nil
    var autoPiPOnExit: Bool? = nil
    var spokenFeedback: Bool? = nil
    var useMemories: Bool? = nil
    var liveTaskStatus: Bool? = nil
    static func isBedrock(_ endpoint: String) -> Bool {
        let host = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host.hasPrefix("bedrock-runtime.") && host.hasSuffix(".amazonaws.com")
    }
    /// Bedrock answers chat questions; the phone agent needs an OpenAI-compatible endpoint.
    var usesBedrock: Bool { Self.isBedrock(endpoint) }
    var responseTokenLimit: Int { max(1024, min(16384, maxResponseTokens ?? 4096)) }
}

/// The touch-probe calibration (CalibrationView): mouse units per screen point and where the homed corner
/// lands, per axis. BrainPointer adopts it and keeps learning corrections from where its taps land.
struct PointerCalibration: Codable {
    var screenWidth: Double
    var screenHeight: Double
    var gainX: Double
    var gainY: Double
    var originX: Double
    var originY: Double
    var validationError: Double
    var peripheralID: String
    var createdAt: Date
    // Optional so older stored calibrations still decode; they fail `usable` and ask for a new calibration.
    var movementVersion: Int? = nil
    var calibrationVersion: Int? = nil
    var fitSampleCount: Int? = nil
    var validationSampleCount: Int? = nil
    var validationRMS: Double? = nil
    var returnDrift: Double? = nil
    var usable: Bool {
        movementVersion == PointerMotion.profileVersion && calibrationVersion == CalibrationSolver.probeVersion &&
        (fitSampleCount ?? 0) >= CalibrationSolver.probeMinimumFitSamples && (validationSampleCount ?? 0) >= 1 &&
        validationRMS.map { $0.isFinite && (0...CalibrationSolver.maxValidationRMS).contains($0) } == true &&
        returnDrift.map { $0.isFinite && (0...CalibrationSolver.maxReturnDrift).contains($0) } == true &&
        [screenWidth, screenHeight, gainX, gainY, originX, originY, validationError].allSatisfy(\.isFinite) &&
        screenWidth > 0 && screenHeight > 0 && gainX > 0.1 && gainY > 0.1 &&
        (0...CalibrationSolver.maxValidationError).contains(validationError)
    }
}

enum PointerMotion {
    // Profile 7 is the fast-agent pace (25 counts per 20 ms report); older calibrations need redoing.
    static let profileVersion = 7
    static let reportDistance = 25.0
    static let reportInterval = 0.020
    static func reportCount(x: Int, y: Int) -> Int { Int(ceil(hypot(Double(x), Double(y)) / reportDistance)) }
}

/// Acceptance limits of the touch-probe calibration (a per-axis line fit from about 8 clicks).
enum CalibrationSolver {
    static let probeVersion = 3
    static let probeMinimumFitSamples = 4
    static let probeSteps = 8
    static let maxValidationError = 8.0
    static let maxValidationRMS = 6.0
    static let maxReturnDrift = 8.0
}

/// One Fast agent action as the app's UI, approvals, Live Activity and PiP show it (BrainActions.agentAction).
struct AgentAction: Equatable {
    enum Kind: String { case tap, drag, type, press_key, wait, finish, ask_user }
    var kind: Kind
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    var text: String?
    var seconds: Double?
    var reason: String

    var label: String {
        switch kind {
        case .tap: return "Tap"
        case .drag: return "Swipe"
        case .type: return "Type text"
        case .press_key: return "Key \(text ?? "")"
        case .wait: return "Wait"
        case .finish: return "Done"
        case .ask_user: return "Needs your action"
        }
    }
}

struct AgentLogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var step: Int
    var title: String
    var detail: String
}
