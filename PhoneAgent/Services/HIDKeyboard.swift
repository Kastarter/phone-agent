import Foundation

enum HIDKeyboard {
    static func ascii(_ c: Character, capsLock: Bool = false) throws -> (UInt8, UInt8) {
        guard let value = c.asciiValue else { throw AgentError.message("The hardware keyboard supports ASCII only. Use the on-screen keyboard for other characters") }
        switch value {
        case 97...122: return (capsLock ? 2 : 0, value - 97 + 4)
        case 65...90: return (capsLock ? 0 : 2, value - 65 + 4)
        case 49...57: return (0, value - 49 + 30)
        case 48: return (0, 39)
        case 10,13: return (0,40)
        case 9: return (0,43)
        case 32: return (0,44)
        default:
            let plain = "-=[]\\;'`,./"
            let shifted = "_+{}|:\"~<>?"
            let usage: [UInt8] = [45,46,47,48,49,51,52,53,54,55,56]
            if let i = Array(plain).firstIndex(of: c) { return (0, usage[i]) }
            if let i = Array(shifted).firstIndex(of: c) { return (2, usage[i]) }
            let digits = "!@#$%^&*()"
            if let i = Array(digits).firstIndex(of: c) { return (2, i == 9 ? 39 : UInt8(30 + i)) }
            throw AgentError.message("Character not supported yet: \(c)")
        }
    }
    static func key(_ name: String) throws -> (UInt8, UInt8) {
        switch name.lowercased() {
        case "enter": return (0,40)
        case "escape": return (0,41)
        case "backspace": return (0,42)
        case "tab": return (0,43)
        case "space": return (0,44)
        case "delete": return (0,76)
        case "right": return (0,79)
        case "left": return (0,80)
        case "down": return (0,81)
        case "up": return (0,82)
        case "page_up": return (0,75)
        case "page_down": return (0,78)
        case "line_start": return (8,80) // Command-Left; "home" remains the phone Home action.
        case "line_end": return (8,79)
        case "select_all": return (8,4) // Left GUI + A (Command-A).
        case "copy": return (8,6)
        case "paste": return (8,25)
        case "cut": return (8,27)
        case "undo": return (8,29)
        case "redo": return (10,29) // Command-Shift-Z.
        case "switch_input": return (1,44) // Control-Space; observe the active input source.
        default: throw AgentError.message("Unknown key: \(name)")
        }
    }
    /// "cmd+a", "esc", "cmd+shift+z": modifiers plus exactly one key. Cmd+H is refused: iOS ignores it from the stick.
    static func combo(_ text: String) throws -> (UInt8, UInt8) {
        let modifiers: [String: UInt8] = ["ctrl": 1, "control": 1, "shift": 2, "alt": 4, "option": 4,
                                          "cmd": 8, "command": 8, "gui": 8]
        var mask: UInt8 = 0, keys: [(UInt8, UInt8)] = []
        for raw in text.split(separator: "+", omittingEmptySubsequences: false) {
            let original = raw.trimmingCharacters(in: .whitespaces), token = original.lowercased()
            if let m = modifiers[token] { mask |= m; continue }
            let name = ["esc": "escape", "return": "enter"][token] ?? token
            if let k = try? key(name) { keys.append(k) }
            else if original.count == 1, let c = original.first, let k = try? ascii(c) { keys.append(k) }
            else { throw AgentError.message("Unknown key combo: \(text)") }
        }
        guard keys.count == 1 else { throw AgentError.message("Unknown key combo: \(text)") }
        let combo = (mask | keys[0].0, keys[0].1)
        guard !(combo.0 & 8 != 0 && combo.1 == 11) else { throw AgentError.message("Cmd+H does nothing on iPhone; use home") }
        return combo
    }
}

// MARK: - Typing by keystrokes
extension HIDKeyboard {
    /// Reports for firmware without timed key sequences: a release separates a repeated key or a
    /// modifier change; a different key under the same modifiers rolls straight over. Ends released.
    static func reports(_ keys: [(UInt8, UInt8)]) -> [(UInt8, UInt8)] {
        var out: [(UInt8, UInt8)] = [], held: (UInt8, UInt8)?
        for key in keys {
            if let h = held, h.0 != key.0 || h.1 == key.1 { out.append((0, 0)) }
            out.append(key); held = key
        }
        if held != nil { out.append((0, 0)) }
        return out
    }
}
