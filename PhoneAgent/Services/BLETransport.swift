import Foundation
import CoreBluetooth
import Combine

struct AgentPeripheral: Identifiable {
    let peripheral: CBPeripheral
    var id: UUID { peripheral.identifier }
    var name: String { peripheral.name ?? "AgentMouse" }
}

@MainActor
final class BLETransport: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [AgentPeripheral] = []
    @Published private(set) var state = "Starting Bluetooth"
    @Published private(set) var connected = false
    @Published private(set) var scanning = false
    @Published private(set) var status: MouseProtocol.Status?
    @Published private(set) var error = ""
    @Published private(set) var selectedID: String?
    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var command: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var taskIndicatorChar: CBCharacteristic?
    private var desiredIndicator: MouseProtocol.TaskIndicator = .idle
    private var sentIndicator: MouseProtocol.TaskIndicator?
    private var indicatorSentAt = Date.distantPast
    private var sequence: UInt16 = 0
    private var writer: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var serviceTimeout: Task<Void, Never>?
    private var poll: Timer?
    private var pairingInProgress = false
    private var secureSessionReady = false
    private var connectionGeneration = UUID()
    var pointerConnectionGeneration: UUID { connectionGeneration }
    private var diagnosticLines: [String] = []
    private var lastFlags: UInt8?
    private var latestStatus: MouseProtocol.Status?
    private var pointerMotionTokens = Set<UUID>()
    var ready: Bool { connected && secureSessionReady && command != nil && status?.ready == true }
    var keyboardReady: Bool { ready && status?.keyboardAvailable == true }
    var bufferedMotionReady: Bool { ready && status?.bufferedMotionAvailable == true }
    var consumerReady: Bool { ready && status?.consumerAvailable == true }
    /// Firmware with op 7 types queued keystrokes on its own clock; older boards type per key.
    var keySequenceReady: Bool { keyboardReady && status?.keySequenceSupported == true }
    struct KeyTiming {
        let keys: Int, milliseconds: Double, batched: Bool
        var perKeyMS: Double { keys > 0 ? milliseconds / Double(keys) : 0 }
        var summary: String {
            String(format: "%d keys %.0f ms, %.1f ms/key (%@)", keys, milliseconds, perKeyMS, batched ? "board-timed" : "per-key writes")
        }
    }
    /// Timing of the most recent typeKeys call, for traces.
    private(set) var lastTyping: KeyTiming?
    var writable: Bool { ready && writer == nil && status?.busy != true }

    override init() {
        super.init()
        record("App started; secure-handshake build")
        central = CBCentralManager(delegate: self, queue: .main)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.flushTaskIndicator() }
        }
    }
    deinit { poll?.invalidate() }
    private func record(_ text: String) {
        diagnosticLines.append("\(Date().ISO8601Format()) \(text)")
        diagnosticLines = Array(diagnosticLines.suffix(150))
        let file = URL.documentsDirectory.appendingPathComponent("ble-diagnostics.log")
        try? diagnosticLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    func scan() {
        guard central.state == .poweredOn else {
            error = central.state == .unauthorized ? "Allow Phone Agent to use Bluetooth in iPhone Settings" : "Turn on iPhone Bluetooth first"
            return
        }
        guard !connected, peer == nil, !scanning else { return }
        devices = []; error = ""; scanning = true; state = "Looking for AgentMouse… it will connect automatically when found"
        record("Scan requested")
        let active = central.retrieveConnectedPeripherals(withServices: [MouseProtocol.hid, MouseProtocol.service])
        if let peripheral = active.first(where: { $0.name?.hasPrefix("AgentMouse") == true }) {
            let device = AgentPeripheral(peripheral: peripheral)
            add(peripheral)
            connect(device)
            return
        }
        // The control UUID is in the accessory's BLE scan response. An unfiltered scan
        // also sees devices that advertise only HID in their primary advertisement.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.scanning else { return }
            self.stopScan()
            if self.devices.isEmpty {
                self.error = "AgentMouse not found. Make sure the accessory is powered and iPhone Bluetooth is on. Pair a new device first in iOS AssistiveTouch > Devices > Bluetooth Devices, then come back here to connect."
                self.state = "Accessory not found"
            }
        }
    }
    func stopScan() { central.stopScan(); scanTimeout?.cancel(); scanTimeout = nil; scanning = false }
    private func add(_ p: CBPeripheral) {
        if !devices.contains(where: { $0.id == p.identifier }) { devices.append(AgentPeripheral(peripheral: p)) }
    }
    func connect(_ d: AgentPeripheral) {
        guard central.state == .poweredOn, !connected, peer == nil else { return }
        stopScan(); state = "Connecting to \(d.name)"; error = ""
        peer = d.peripheral; selectedID = d.id.uuidString; peer?.delegate = self
        connectionGeneration = UUID()
        desiredIndicator = .idle; sentIndicator = nil; indicatorSentAt = .distantPast
        record("Connect requested: \(d.id)")
        central.connect(d.peripheral, options: nil)
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.error = "App connection timed out. Make sure AgentMouse is paired in iOS AssistiveTouch > Devices. If you just paired it, turn AssistiveTouch off and on, then try again here."
            self.disconnect()
        }
    }
    func disconnect() { if let peer { central.cancelPeripheralConnection(peer) } }
    func beginPointerMotion() -> UUID {
        let token = UUID(); pointerMotionTokens.insert(token); return token
    }
    func endPointerMotion(_ token: UUID) { pointerMotionTokens.remove(token) }
    func recordPointerTiming(reports: Int, expectedMS: Double, maxAcknowledgementMS: Double, maxIntervalMS: Double) {
        guard reports > 0 else { return }
        // One aggregate after the move; no file writes inside the report loop.
        record(String(format: "Motion reports=%d expected=%.1fms maxAck=%.1fms maxInterval=%.1fms",
            reports, expectedMS, maxAcknowledgementMS, maxIntervalMS))
    }
    func refresh(afterBufferedMove: Bool = false) {
        // A periodic ATT read can occupy the request/response channel between
        // movement reports. Notifications still deliver errors/readiness while
        // moving, so status polling is reserved for gaps between movements.
        if connected, !pairingInProgress, writer == nil, (pointerMotionTokens.isEmpty || afterBufferedMove),
           let peer, let statusChar { peer.readValue(for: statusChar) }
    }
    func setTaskIndicator(_ value: MouseProtocol.TaskIndicator) {
        desiredIndicator = value
        flushTaskIndicator()
    }
    private func flushTaskIndicator() {
        // Optional S3 characteristic. LED updates do not enter the serial HID
        // acknowledgement queue, and old firmware simply has no such value.
        guard ready, let peer, let taskIndicatorChar,
              taskIndicatorChar.properties.contains(.writeWithoutResponse),
              peer.canSendWriteWithoutResponse else { return }
        guard sentIndicator != desiredIndicator || Date().timeIntervalSince(indicatorSentAt) >= 2 else { return }
        peer.writeValue(Data([1, desiredIndicator.rawValue]), for: taskIndicatorChar, type: .withoutResponse)
        sentIndicator = desiredIndicator; indicatorSentAt = Date()
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        if p === peer { flushTaskIndicator() }
    }
    func send(_ op: MouseProtocol.Operation, buttons: UInt8 = 0, x: Int = 0, y: Int = 0,
              wheel: Int = 0, delay: UInt16 = 0, pairingHandshake: Bool = false) async throws {
        try Task.checkCancellation()
        guard connected, peer != nil, command != nil else { throw AgentError.message("Bluetooth accessory not connected") }
        guard writer == nil else { throw AgentError.message("Accessory is receiving another command") }
        guard !pairingInProgress || pairingHandshake else { throw AgentError.message("Establishing secure connection, please wait") }
        guard !pairingHandshake || op == .release else { throw AgentError.message("Invalid connection handshake") }
        if op != .release && !ready { throw AgentError.message("Connect the Bluetooth mouse in AssistiveTouch first") }
        if op != .release && status?.busy == true { throw AgentError.message("Accessory is performing a click") }
        guard op != .consumer else { throw AgentError.message("Use homeScreen() for consumer keys") }
        sequence &+= 1
        let bytes: Data
        if op == .keyboard {
            guard keyboardReady else { throw AgentError.message("Bluetooth keyboard not ready; check the connection on the Device page") }
            guard x == 0 || (4...101).contains(x) else { throw AgentError.message("Invalid keyboard key") }
            bytes = Data([1,4,UInt8(truncatingIfNeeded: sequence),UInt8(sequence >> 8),buttons,
                          UInt8(x),0,0,0,0])
        } else { bytes = MouseProtocol.packet(op, sequence: sequence, buttons: buttons, x: x, y: y, wheel: wheel, delay: delay) }
        try await writeCommand(bytes, pairingHandshake: pairingHandshake)
        if latestStatus?.sequence == sequence, let code = latestStatus?.error, code != 0 {
            throw AgentError.message("Accessory reported error \(code); action stopped")
        }
    }
    /// Presses AC Home on the consumer-control report; the board releases it after 40 ms.
    func homeScreen() async throws {
        try Task.checkCancellation()
        guard connected, peer != nil, command != nil else { throw AgentError.message("Bluetooth accessory not connected") }
        guard writer == nil else { throw AgentError.message("Accessory is receiving another command") }
        guard !pairingInProgress else { throw AgentError.message("Establishing secure connection, please wait") }
        guard ready else { throw AgentError.message("Connect the Bluetooth mouse in AssistiveTouch first") }
        guard status?.busy != true else { throw AgentError.message("Accessory is performing a click") }
        guard consumerReady else { throw AgentError.message("The accessory firmware has no Home key; update the firmware") }
        sequence &+= 1; let home = sequence
        try await writeCommand(MouseProtocol.consumerPacket(sequence: home, usage: MouseProtocol.acHome))
        try await waitIdle()
        if latestStatus?.sequence == home, let code = latestStatus?.error, code != 0 {
            throw AgentError.message("Accessory reported error \(code); action stopped")
        }
    }
    private func writeCommand(_ bytes: Data, pairingHandshake: Bool = false) async throws {
        guard let peer, let command, writer == nil else { throw AgentError.message("Unexpected Bluetooth write state") }
        try await withCheckedThrowingContinuation { continuation in
            writer = continuation
            if pairingHandshake { record("Encrypted release handshake: write submitted; timeout=35s") }
            peer.writeValue(bytes, for: command, type: .withResponse)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: pairingHandshake ? 35_000_000_000 : 3_000_000_000)
                guard !Task.isCancelled, let self, let writer = self.writer else { return }
                self.writer = nil
                self.error = pairingHandshake ? "Secure connection didn't complete; stopped waiting. Reconnect, and if it still fails, check the pairing record." : "Bluetooth write timed out; execution stopped"
                self.record(pairingHandshake ? "Handshake timed out" : "Command write timed out")
                writer.resume(throwing: AgentError.message(self.error))
                // Disconnect before permitting another write: late ATT responses have no transaction ID.
                self.command = nil; self.central.cancelPeripheralConnection(peer)
            }
        }
        try Task.checkCancellation()
    }
    /// Types (modifier, usage) keystrokes. New firmware: batches of up to 24 keys, pipelined so the
    /// board's 64-key queue never runs dry (~20 ms per key). Old firmware: one acknowledged write per
    /// report, no sleeps, releases only where a repeat or modifier change needs one.
    func typeKeys(_ keys: [(UInt8, UInt8)]) async throws {
        guard !keys.isEmpty else { return }
        try Task.checkCancellation()
        guard keys.allSatisfy({ (4...101).contains($0.1) }) else { throw AgentError.message("Invalid keyboard key") }
        guard keyboardReady else { throw AgentError.message("Bluetooth keyboard not ready; check the connection on the Device page") }
        guard writer == nil, latestStatus?.busy != true else { throw AgentError.message("Accessory is still performing the previous action") }
        let connection = connectionGeneration, batched = keySequenceReady, began = ContinuousClock.now
        do {
            if batched { try await typeBatched(keys, connection: connection) }
            else { for (modifier, key) in HIDKeyboard.reports(keys) { try await send(.keyboard, buttons: modifier, x: Int(key)) } }
        } catch {
            // A fresh task can release even when its parent was cancelled; RELEASE also empties the board's queue.
            await Task { @MainActor in if self.connectionGeneration == connection { await self.release() } }.value
            throw error
        }
        let elapsed = began.duration(to: .now).components
        let timing = KeyTiming(keys: keys.count, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, batched: batched)
        lastTyping = timing; record("Typed \(timing.summary)")
    }
    private func typeBatched(_ keys: [(UInt8, UInt8)], connection: UUID) async throws {
        let limit = MouseProtocol.keyBatchLimit(maximumWrite: peer?.maximumWriteValueLength(for: .withResponse) ?? 20)
        let keyMS = Double(MouseProtocol.keyDownMS) + Double(MouseProtocol.keyUpMS)
        var queued: [(sequence: UInt16, count: Int)] = [], cursor = 0, sawBusy = false
        var progress = ContinuousClock.now
        while cursor < keys.count || !queued.isEmpty {
            try Task.checkCancellation()
            guard keyboardReady, connectionGeneration == connection else { throw AgentError.message("The keyboard connection changed while typing") }
            if let s = latestStatus {
                if let done = queued.firstIndex(where: { $0.sequence == s.sequence }) {
                    guard s.error == 0 else { throw AgentError.message("Accessory reported error \(s.error) while typing") }
                    queued.removeFirst(done + 1); progress = .now
                } else if s.busy { sawBusy = true }
                else if sawBusy, !queued.isEmpty {
                    throw AgentError.message(s.error != 0 ? "Typing stopped, accessory error \(s.error)" : "The accessory stopped typing")
                }
            }
            let next = min(limit, keys.count - cursor)
            if next > 0, writer == nil, queued.reduce(0, { $0 + $1.count }) + next <= MouseProtocol.keyQueueSize {
                sequence &+= 1; let batch = sequence
                try await writeCommand(MouseProtocol.keySequencePacket(sequence: batch, keys: keys[cursor..<cursor + next]))
                queued.append((batch, next)); cursor += next; progress = .now
                continue
            }
            let budget = Double(queued.reduce(0) { $0 + $1.count }) * keyMS / 1000 + 1.5
            guard progress.duration(to: .now) < .seconds(budget) else { throw AgentError.message("Timed out waiting for the accessory to type") }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }
    func moveBuffered(x: Int, y: Int, buttons: UInt8 = 0, reports: Int, intervalMS: Int) async throws {
        try Task.checkCancellation()
        guard bufferedMotionReady else { throw AgentError.message("Update the accessory to firmware with on-board smooth movement before calibrating") }
        guard writer == nil, latestStatus?.busy != true else { throw AgentError.message("Accessory is still performing the previous action") }
        guard abs(x) < 10000, abs(y) < 10000, buttons <= 7, (1...2000).contains(reports),
              (20...100).contains(intervalMS), reports * intervalMS <= 80000,
              (abs(x) + reports - 1) / reports <= 127, (abs(y) + reports - 1) / reports <= 127 else {
            throw AgentError.message("Invalid on-board movement parameters")
        }
        let connection = connectionGeneration
        sequence &+= 1; let moveSequence = sequence
        let duration = Double(reports * intervalMS) / 1000
        let began = ContinuousClock.now
        try await writeCommand(MouseProtocol.movementPacket(sequence: moveSequence, buttons: buttons,
            x: x, y: y, reports: reports, intervalMS: intervalMS))
        let ackTime = began.duration(to: .now).components
        let ackMS = Double(ackTime.seconds) * 1000 + Double(ackTime.attoseconds) / 1e15
        let expectedEnd = began.advanced(by: .seconds(duration + 0.35))
        let deadline = expectedEnd.advanced(by: .seconds(5))
        var nextRead = expectedEnd
        while true {
            try Task.checkCancellation()
            guard ready, connectionGeneration == connection else { throw AgentError.message("Connection changed during on-board movement") }
            guard sequence == moveSequence else { throw AgentError.message("On-board movement was interrupted") }
            if let s = latestStatus, s.sequence == moveSequence {
                guard s.error == 0 else { throw AgentError.message("On-board movement failed, accessory error \(s.error)") }
                if !s.busy {
                    record(String(format: "Buffered motion seq=%u reports=%d interval=%dms startAck=%.1fms completed",
                        moveSequence, reports, intervalMS, ackMS))
                    return
                }
            }
            let now = ContinuousClock.now
            guard now < deadline else { throw AgentError.message("Timed out waiting for on-board movement; positioning stopped") }
            // Recovery reads begin only after the trajectory should have ended.
            if now >= nextRead { refresh(afterBufferedMove: true); nextRead = now.advanced(by: .seconds(0.25)) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func release() async {
        for _ in 0..<100 {
            if writer == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await send(.release)
    }
    func waitIdle() async throws {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            try Task.checkCancellation()
            refresh()
            try await Task.sleep(nanoseconds: 80_000_000)
            guard ready else { throw AgentError.message("Mouse connection lost") }
            if status?.busy != true { return }
        } while Date() < deadline
        throw AgentError.message("Timed out waiting for the accessory to release the button")
    }
    private func clear() {
        timeout?.cancel(); connectTimeout?.cancel(); scanTimeout?.cancel(); serviceTimeout?.cancel()
        writer?.resume(throwing: AgentError.message("Accessory disconnected")); writer = nil
        peer = nil; command = nil; statusChar = nil; taskIndicatorChar = nil; connected = false; status = nil; selectedID = nil
        latestStatus = nil; pointerMotionTokens.removeAll()
        pairingInProgress = false; secureSessionReady = false; lastFlags = nil
        desiredIndicator = .idle; sentIndicator = nil; indicatorSentAt = .distantPast
        connectionGeneration = UUID()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        record("Central state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            state = "Bluetooth is on"
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--connect-accessory") { scan() }
            #endif
        }
        else { stopScan(); clear(); state = central.state == .unauthorized ? "Allow Bluetooth access" : "Turn on Bluetooth" }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.hasPrefix("AgentMouse") else { return }
        add(peripheral)
        if peer == nil && !connected { connect(AgentPeripheral(peripheral: peripheral)) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peer?.identifier == peripheral.identifier else { return }
        record("Connected; discovering control service")
        connectTimeout?.cancel(); connected = true; state = "Connected, checking accessory…"
        peripheral.discoverServices([MouseProtocol.service])
        serviceTimeout?.cancel()
        serviceTimeout = Task { [weak self, weak peripheral] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self, let peripheral,
                  self.peer?.identifier == peripheral.identifier, self.command == nil else { return }
            self.error = "Bluetooth connected, but the accessory's control service didn't respond. Make sure the AgentMouse firmware is running."
            self.central.cancelPeripheralConnection(peripheral)
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        record("Connect failed: \(String(describing: error))")
        self.error = "iPhone connection failed: \(error?.localizedDescription ?? "please try again"). If you just paired, turn AssistiveTouch off and on, then try again."
        clear(); state = "Connection failed"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        record("Disconnected: \(String(describing: error))")
        if let error { self.error = error.localizedDescription }; clear(); state = "Accessory disconnected"
    }
    func peripheral(_ p: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard p === peer, command != nil,
              invalidatedServices.contains(where: { $0.uuid == MouseProtocol.service }) else { return }
        // Never continue pointer writes with invalidated ATT handles.
        command = nil; taskIndicatorChar = nil; secureSessionReady = false
        error = "Accessory control service changed; please reconnect"
        record("Control service invalidated; disconnecting stale handles")
        central.cancelPeripheralConnection(p)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peer else { return }
        record("Services: \(p.services?.map { $0.uuid.uuidString } ?? []); error=\(String(describing: error))")
        guard error == nil, let service = p.services?.first(where: { $0.uuid == MouseProtocol.service }) else {
            self.error = error.map { "Couldn't read Bluetooth services: \($0.localizedDescription)" } ?? "Accessory control service not found; check the firmware version."
            return
        }
        p.discoverCharacteristics([MouseProtocol.command, MouseProtocol.status, MouseProtocol.taskIndicator], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peer else { return }
        record("Characteristics discovered; error=\(String(describing: error))")
        command = service.characteristics?.first(where: { $0.uuid == MouseProtocol.command })
        statusChar = service.characteristics?.first(where: { $0.uuid == MouseProtocol.status })
        taskIndicatorChar = service.characteristics?.first(where: { $0.uuid == MouseProtocol.taskIndicator })
        record("Task RGB characteristic: \(taskIndicatorChar != nil)")
        guard error == nil, command?.properties.contains(.write) == true,
              let statusChar, statusChar.properties.contains(.read) else {
            self.error = error.map { "Couldn't read accessory characteristics: \($0.localizedDescription)" } ?? "Control service is incomplete; check the ESP32 firmware."
            return
        }
        serviceTimeout?.cancel(); serviceTimeout = nil
        p.setNotifyValue(true, for: statusChar)
        // The unencrypted status characteristic cannot trigger system pairing.
        // Access the encrypted command characteristic once, with a separate
        // pairing deadline. A release never generates a click or movement.
        pairingInProgress = true; secureSessionReady = false
        state = "Establishing secure connection… if iOS asks to pair, tap Pair"
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, generation == self.connectionGeneration else { return }
            do {
                try await self.send(.release, pairingHandshake: true)
                guard generation == self.connectionGeneration else { return }
                self.pairingInProgress = false; self.secureSessionReady = true
                self.record("Secure handshake acknowledged")
                self.state = "Secure connection established, reading mouse status…"
                self.refresh(); self.flushTaskIndicator()
            } catch {
                guard generation == self.connectionGeneration else { return }
                self.pairingInProgress = false
                self.record("Secure handshake failed: \(error)")
                self.error = error.localizedDescription
                self.state = "Secure connection failed; please reconnect"
                self.disconnect()
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { self.error = error.localizedDescription }; refresh()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p === peer else { return }
        if let error { record("Status read failed: \(error)") }
        guard error == nil, c.uuid == MouseProtocol.status, let bytes = c.value, let s = MouseProtocol.Status(bytes) else { return }
        if lastFlags != s.flags {
            lastFlags = s.flags
            record("Status flags=\(s.flags) encrypted=\(s.encrypted) hid=\(s.hidSubscribed)")
        }
        // Preserve the full latest sequence for transport checks. Sequence-only
        // notifications don't need to redraw the whole SwiftUI app at 25 Hz.
        latestStatus = s
        if status?.flags != s.flags || status?.buttons != s.buttons ||
            status?.error != s.error || status?.keyboardAvailable != s.keyboardAvailable ||
            status?.keyboardSupported != s.keyboardSupported || status?.capsLock != s.capsLock ||
            status?.bufferedMotionAvailable != s.bufferedMotionAvailable ||
            status?.consumerAvailable != s.consumerAvailable || status?.consumerSupported != s.consumerSupported ||
            status?.keySequenceSupported != s.keySequenceSupported { status = s }
        let nextState: String
        if pairingInProgress { nextState = "Establishing secure connection… if iOS asks to pair, tap Pair" }
        else if ready { nextState = "Mouse ready" }
        else if !s.encrypted { nextState = "Connection isn't encrypted yet; reconnect the accessory" }
        else if !s.hidSubscribed { nextState = "Bluetooth connected; connect AgentMouse as a mouse in AssistiveTouch" }
        else if s.suspended { nextState = "iOS paused the mouse; wake the screen or reconnect" }
        else { nextState = "Preparing mouse…" }
        if state != nextState { state = nextState }
        flushTaskIndicator()
        if s.error == 5, self.error != "Accessory button held too long; release protection triggered" {
            self.error = "Accessory button held too long; release protection triggered"
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peer, c.uuid == MouseProtocol.command, let writer else { return }
        if pairingInProgress || error != nil { record("Write response: \(String(describing: error))") }
        timeout?.cancel(); self.writer = nil
        if let error { self.error = error.localizedDescription; writer.resume(throwing: error) }
        else { writer.resume(); if !self.error.isEmpty { self.error = "" } }
    }
}
