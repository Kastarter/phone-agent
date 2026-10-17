import Foundation

@MainActor
final class MouseExecutor {
    let ble: BLETransport
    var calibrationInProgress = false
    /// The touch-probe calibration BrainPointer adopts; the pointer then learns its own corrections.
    var calibration: PointerCalibration?
    init(ble: BLETransport) {
        self.ble = ble
        if let saved = SettingsStore.calibration(), saved.usable { calibration = saved }
    }
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(max(0, min(10, seconds)) * 1_000_000_000))
    }
    func homePointer() async throws {
        // Physical pointer homing, not the phone's Home action.
        let motionToken = ble.beginPointerMotion()
        defer { ble.endPointerMotion(motionToken) }
        let connection = ble.pointerConnectionGeneration
        do {
            try await ble.moveBuffered(x: -127 * 20, y: -127 * 20, reports: 20, intervalMS: 20)
            try await sleep(0.08)
            guard ble.ready, ble.pointerConnectionGeneration == connection else { throw AgentError.message("The mouse connection changed") }
        } catch {
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release() }
            }.value
            throw error
        }
    }
    func movePositionUnits(x: Int, y: Int) async throws {
        guard abs(x) < 10000, abs(y) < 10000 else { throw AgentError.message("Unusual move distance. Recalibrate.") }
        let motionToken = ble.beginPointerMotion()
        defer { ble.endPointerMotion(motionToken) }
        let connection = ble.pointerConnectionGeneration
        let reports = PointerMotion.reportCount(x: x, y: y)
        guard reports > 0 else { return }
        do {
            try await ble.moveBuffered(x: x, y: y, reports: reports,
                intervalMS: Int((PointerMotion.reportInterval * 1000).rounded()))
            guard ble.pointerConnectionGeneration == connection else { throw AgentError.message("The connection changed; movement stopped") }
        } catch {
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release() }
            }.value
            throw error
        }
    }
    func click() async throws {
        try await ble.send(.click, buttons: 1)
        try await sleep(0.16)
        try await ble.waitIdle()
    }
    func validateCalibration(frame: ScreenFrame? = nil) throws -> PointerCalibration {
        guard !calibrationInProgress else { throw AgentError.message("Calibration isn't finished yet. Please wait.") }
        guard let c = calibration, c.usable, c.peripheralID == ble.selectedID else {
            throw AgentError.message("Calibrate pointer positioning for this accessory first")
        }
        if let frame {
            let actual = Double(frame.sourceWidth) / Double(max(1, frame.sourceHeight))
            let expected = c.screenWidth / c.screenHeight
            guard abs(actual - expected) < 0.035 else { throw AgentError.message("Screen rotation or capture scale changed. Return to portrait and recalibrate.") }
        }
        return c
    }
    func pressCombo(_ modifier: UInt8, _ key: UInt8) async throws { try await press(modifier: modifier, key: key) }
    private func press(modifier: UInt8, key: UInt8) async throws {
        guard ble.keyboardReady else { throw AgentError.message("The Bluetooth keyboard isn't ready") }
        let connection = ble.pointerConnectionGeneration
        do {
            try await ble.send(.keyboard, buttons: modifier, x: Int(key))
            try await sleep(0.045)
            try await ble.send(.keyboard, x: 0)
            try await sleep(0.045)
        } catch {
            // A fresh task can release even when its parent was cancelled.
            await Task { @MainActor in
                if ble.pointerConnectionGeneration == connection { await ble.release() }
            }.value
            throw error
        }
    }
}
