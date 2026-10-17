import Foundation
import CoreBluetooth

enum MouseProtocol {
    static let service = CBUUID(string: "A1000001-7A3B-4F45-9F11-123456789ABC")
    static let command = CBUUID(string: "A1000002-7A3B-4F45-9F11-123456789ABC")
    static let status = CBUUID(string: "A1000003-7A3B-4F45-9F11-123456789ABC")
    static let taskIndicator = CBUUID(string: "A1000004-7A3B-4F45-9F11-123456789ABC")
    enum TaskIndicator: UInt8 { case idle = 0, running = 1, failed = 2, completed = 3 }
    static let hid = CBUUID(string: "1812")

    // 5 is the 14-byte buffered move (movementPacket).
    enum Operation: UInt8 { case report = 1, click = 2, release = 3, keyboard = 4, consumer = 6 }
    static let acHome: UInt16 = 0x0223
    static func packet(_ op: Operation, sequence: UInt16, buttons: UInt8 = 0,
                       x: Int = 0, y: Int = 0, wheel: Int = 0, delay: UInt16 = 0) -> Data {
        func signed(_ v: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, v)))) }
        return Data([1, op.rawValue, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8),
                     buttons & 7, signed(x), signed(y), signed(wheel),
                     UInt8(truncatingIfNeeded: delay), UInt8(delay >> 8)])
    }
    static func movementPacket(sequence: UInt16, buttons: UInt8, x: Int, y: Int,
                               reports: Int, intervalMS: Int) -> Data {
        let dx = UInt16(bitPattern: Int16(x)), dy = UInt16(bitPattern: Int16(y))
        func low(_ value: UInt16) -> UInt8 { UInt8(truncatingIfNeeded: value) }
        func high(_ value: UInt16) -> UInt8 { UInt8(value >> 8) }
        return Data([2, 5, low(sequence), high(sequence), buttons,
                     low(dx), high(dx), low(dy), high(dy),
                     low(UInt16(reports)), high(UInt16(reports)),
                     low(UInt16(intervalMS)), high(UInt16(intervalMS)), 0])
    }
    static func consumerPacket(sequence: UInt16, usage: UInt16) -> Data {
        Data([1, Operation.consumer.rawValue, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8),
              0, UInt8(truncatingIfNeeded: usage), UInt8(usage >> 8), 0, 0, 0])
    }
    /// Firmware-timed keystrokes (op 7): [1,7,seq lo,seq hi,count,down ms,up ms, count x (modifier,usage)].
    /// The board presses each key for `down` ms and releases it for `up` ms, so repeats always
    /// get a release. It queues up to `keyQueueSize` keys and publishes a batch's sequence once typed.
    static let keyBatchMax = 24, keyQueueSize = 64
    static let keyDownMS: UInt8 = 12, keyUpMS: UInt8 = 8
    static func keySequencePacket(sequence: UInt16, keys: ArraySlice<(UInt8, UInt8)>,
                                  downMS: UInt8 = keyDownMS, upMS: UInt8 = keyUpMS) -> Data {
        var bytes: [UInt8] = [1, 7, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8),
                              UInt8(keys.count), downMS, upMS]
        for (modifier, usage) in keys { bytes += [modifier, usage] }
        return Data(bytes)
    }
    /// Keys per batch for a given ATT write limit (MTU - 3).
    static func keyBatchLimit(maximumWrite: Int) -> Int { max(1, min(keyBatchMax, (maximumWrite - 7) / 2)) }
    struct Status {
        let flags: UInt8
        let buttons: UInt8
        let error: UInt8
        let sequence: UInt16
        let keyboardAvailable: Bool
        let keyboardSupported: Bool
        let capsLock: Bool
        let bufferedMotionAvailable: Bool
        let consumerAvailable: Bool
        let consumerSupported: Bool
        let keySequenceSupported: Bool
        init?(_ data: Data) {
            let p = Array(data)
            guard p.count == 8, p[0] == 1 else { return nil }
            flags = p[1]; buttons = p[2]; error = p[3]
            sequence = UInt16(p[4]) | UInt16(p[5]) << 8
            keyboardAvailable = p[6] & 2 != 0 && p[7] & 1 != 0
            keyboardSupported = p[6] & 1 != 0 && p[7] & 1 != 0
            capsLock = p[7] & 2 != 0
            bufferedMotionAvailable = p[6] & 4 != 0 && p[7] & 1 != 0
            consumerAvailable = p[6] & 8 != 0 && p[7] & 1 != 0
            consumerSupported = p[6] & 16 != 0 && p[7] & 1 != 0
            keySequenceSupported = p[6] & 32 != 0 && p[7] & 1 != 0
        }
        var encrypted: Bool { flags & 2 != 0 }
        var hidSubscribed: Bool { flags & 4 != 0 }
        var busy: Bool { flags & 8 != 0 }
        var suspended: Bool { flags & 16 != 0 }
        var bootMode: Bool { flags & 32 != 0 }
        var ready: Bool { flags & 7 == 7 && !suspended }
    }
}
