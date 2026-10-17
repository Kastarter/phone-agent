// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation

/// A board command failed or is unknown; its message is the board's "err …" text.
struct DeviceError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// One line of their board's text protocol (docs/ble-protocol.md), parsed for BrainDevice.
enum BrainCommand: Equatable {
    case home, homeCorner(Int, Int), move(Int, Int), press, release, click, scroll(Int, Int), type(String), key(String), homeScreen

    static func parse(_ line: String) throws -> BrainCommand {
        let line = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let head = line.prefix { $0 != " " }
        let rest = head.count < line.count ? String(line.dropFirst(head.count + 1)) : ""
        let numbers = rest.split(separator: " ").map { Int($0) }
        func ints(_ counts: ClosedRange<Int>) throws -> [Int] {
            guard counts.contains(numbers.count), numbers.allSatisfy({ $0 != nil }) else {
                throw DeviceError(message: "err bad arguments: \(line.prefix(80))")
            }
            return numbers.compactMap { $0 }
        }
        switch head.lowercased() {
        case "home" where rest.isEmpty: return .home
        case "home":  // "home 1 1": the corner given by the signs (x: -1 left, 1 right; y: -1 top, 1 bottom)
            let n = try ints(2...2)
            guard n.allSatisfy({ abs($0) == 1 }) else { throw DeviceError(message: "err home corner needs -1 or 1: \(line.prefix(80))") }
            return n == [-1, -1] ? .home : .homeCorner(n[0], n[1])
        case "move": let n = try ints(2...2); return .move(n[0], n[1])
        case "press" where rest.isEmpty: return .press
        case "release" where rest.isEmpty: return .release
        case "click" where rest.isEmpty: return .click
        case "scroll": let n = try ints(1...2); return .scroll(n[0], n.count > 1 ? n[1] : 0)
        case "type": return .type(rest)
        case "key":
            let combo = rest.trimmingCharacters(in: .whitespaces)
            guard !combo.isEmpty else { throw DeviceError(message: "err key needs a combo") }
            return .key(combo)
        case "homescreen" where rest.isEmpty: return .homeScreen
        default: throw DeviceError(message: "err unknown command: \(line.prefix(80))")
        }
    }
}
