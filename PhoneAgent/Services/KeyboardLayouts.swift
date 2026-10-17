import Foundation
import CoreGraphics

/// What each keyboard input source types for the stick's US key positions. iOS maps HID keycodes through the
/// active input source (Apple's Arabic hardware layout, not the PC one), so the maps are learned on the device by
/// Keyboard check and saved; English falls back to the built-in US map. Pure, so it is checked offline.
enum KeyboardLayouts {
    enum Script: String, Codable, CaseIterable {
        case latin, arabic
        var name: String { self == .latin ? "English" : "Arabic" }
    }
    struct Key: Codable, Hashable {
        var modifier: UInt8, usage: UInt8
        init(_ modifier: UInt8, _ usage: UInt8) { self.modifier = modifier; self.usage = usage }
    }
    struct Layout: Codable, Equatable {
        var script: Script
        /// Produced text → the key (with Shift or not) that types it.
        var keys: [String: Key]
        var learnedAt: Date
        var version = KeyboardLayouts.version
        /// What each key types: the inverse map.
        var produced: [Key: String] {
            var out: [Key: String] = [:]
            for (text, key) in keys.merging(common, uniquingKeysWith: { a, _ in a }) where out[key] == nil { out[key] = text }
            return out
        }
        /// The longest learned output that starts `chars` at `i` (most keys type one character; some type two).
        func match(_ chars: [Character], at i: Int) -> (Key, Int)? {
            for n in stride(from: min(3, chars.count - i), through: 1, by: -1) {
                let s = String(chars[i..<i + n])
                if let k = keys[s] ?? common[s] { return (k, n) }
            }
            return nil
        }
    }
    struct Run: Equatable { var script: Script?; var text: String }
    struct Step: Equatable { var source: Script; var keys: [Key]; var text: String }
    enum PlanError: Error, Equatable {
        case unlearned(Script), untypable(Character)
        var message: String {
            switch self {
            case .unlearned(let s): return "err no \(s.name) keyboard learned yet: Run Keyboard check in Phone Agent first"
            case .untypable(let c): return "err can't type \"\(c)\": no learned keyboard has it (emoji can't be typed)"
            }
        }
    }

    static let version = 1
    static let shift: UInt8 = 2
    /// US usages Keyboard check probes: letters, digits and punctuation (0x04-0x38 without Enter, Esc, Backspace,
    /// Tab and Space, which type the same everywhere).
    static let probeUsages: [UInt8] = (0x04...0x38).filter { !(0x28...0x2C).contains($0) }
    static let common: [String: Key] = [" ": Key(0, 0x2C), "\n": Key(0, 0x28), "\t": Key(0, 0x2B)]

    /// The US layout: what each usage types plain and with Shift.
    static let us: [UInt8: (String, String)] = {
        var map: [UInt8: (String, String)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[UInt8(4 + i)] = (String(c), c.uppercased()) }
        for (i, (p, s)) in zip("1234567890", "!@#$%^&*()").enumerated() { map[UInt8(0x1E + i)] = (String(p), String(s)) }
        let punctuation: [(UInt8, String, String)] = [(0x2D, "-", "_"), (0x2E, "=", "+"), (0x2F, "[", "{"), (0x30, "]", "}"),
            (0x31, "\\", "|"), (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"), (0x36, ",", "<"), (0x37, ".", ">"), (0x38, "/", "?")]
        for (u, p, s) in punctuation { map[u] = (p, s) }
        return map
    }()
    /// English when Keyboard check has not run: the US map.
    static let builtinUS: Layout = {
        var keys: [String: Key] = [:]
        for (u, (p, s)) in us { keys[p] = Key(0, u); keys[s] = Key(shift, u) }
        return Layout(script: .latin, keys: keys, learnedAt: .distantPast)
    }()

    /// Arabic or Latin letters; nil for digits, spaces, punctuation and emoji, which type on either source.
    static func script(_ c: Character) -> Script? {
        for u in c.unicodeScalars {
            switch u.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: if u.properties.isAlphabetic { return .latin }
            default: continue
            }
        }
        return nil
    }

    /// Runs of one script; neutral characters join the run they sit in (leading ones the first script run).
    static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        for c in text {
            let s = script(c)
            if let last = out.last, s == nil || last.script == nil || last.script == s {
                out[out.count - 1].text.append(c)
                if last.script == nil { out[out.count - 1].script = s }
            } else { out.append(Run(script: s, text: String(c))) }
        }
        return out
    }

    /// Keystrokes per source, switching only when a character needs it. Letters need their script's source; a neutral
    /// character stays on the current source when its map has it, else the next letter's source, else any.
    static func plan(_ text: String, layouts: [Script: Layout], active: Script?) throws -> [Step] {
        let chars = Array(text)
        var steps: [Step] = [], current = active, i = 0
        while i < chars.count {
            let need = script(chars[i])
            if let need, layouts[need] == nil { throw PlanError.unlearned(need) }
            var order: [Script]
            if let need { order = [need] } else {
                let next = chars[i...].lazy.compactMap(script).first
                order = [current, next].compactMap { $0 } + Script.allCases
            }
            guard let (source, key, n) = order.lazy.compactMap({ s in layouts[s]?.match(chars, at: i).map { (s, $0.0, $0.1) } }).first else {
                throw PlanError.untypable(chars[i])
            }
            if steps.last?.source == source {
                steps[steps.count - 1].keys.append(key); steps[steps.count - 1].text += String(chars[i..<i + n])
            } else { steps.append(Step(source: source, keys: [key], text: String(chars[i..<i + n]))) }
            current = source; i += n
        }
        return steps
    }

    /// What the keys type on `layout`: shows what text came out when the wrong source was active.
    static func render(_ keys: [Key], in layout: Layout) -> String {
        let produced = layout.produced
        return keys.map { produced[$0] ?? "" }.joined()
    }

    /// A layout from Keyboard check's (key, what the field received) samples; the script is the majority of the
    /// letters typed. Plain keys win over Shift when both type the same text. Nil when too few letters arrived.
    static func learn(_ samples: [(Key, String)], at date: Date = Date()) -> Layout? {
        var keys: [String: Key] = [:], counts: [Script: Int] = [:]
        for (key, out) in samples.filter({ $0.0.modifier == 0 }) + samples.filter({ $0.0.modifier != 0 }) {
            guard !out.isEmpty, out.count <= 3, !out.allSatisfy(\.isWhitespace) else { continue }
            for c in out { if let s = script(c) { counts[s, default: 0] += 1 } }
            if keys[out] == nil { keys[out] = key }
        }
        let arabic = counts[.arabic] ?? 0, latin = counts[.latin] ?? 0
        guard arabic + latin >= 10 else { return nil }
        return Layout(script: arabic > latin ? .arabic : .latin, keys: keys, learnedAt: date)
    }

    // MARK: Which source the on-screen keyboard shows

    private static let latinRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let arabicRows = ["ضصثقفغعهخحج", "شسيبلاتنمكة", "ءظطذدزروى"]
    /// The keyboard area: key labels sit below this (top-left normalized y).
    static let keyboardTop = 0.6

    /// The active source from OCR labels of the screen (normalized top-left boxes): single-character key labels,
    /// or whole key rows read as one word, below `keyboardTop`. Nil when no keyboard shows or it is unclear.
    static func activeSource(_ labels: [(text: String, box: CGRect)]) -> Script? {
        var counts: [Script: Int] = [:]
        for (text, box) in labels where box.midY > keyboardTop {
            for token in text.split(whereSeparator: \.isWhitespace).map({ String($0).lowercased() }) {
                let reversed = String(token.reversed())
                let row = token.count >= 3 && (latinRows + arabicRows).contains { $0.contains(token) || $0.contains(reversed) }
                guard token.count <= 2 || row else { continue }
                for c in token { if let s = script(c) { counts[s, default: 0] += 1 } }
            }
        }
        let a = counts[.arabic] ?? 0, l = counts[.latin] ?? 0
        guard a + l >= 3 else { return nil }
        return a >= 2 * l ? .arabic : l >= 2 * a ? .latin : nil
    }

    // MARK: Checking what was typed

    /// For comparing typed text with OCR: case, spaces, punctuation, Arabic diacritics, tatweel and letter forms
    /// (أ إ آ → ا, ى ئ → ي, ة → ه, ؤ → و, presentation forms) folded away.
    static func normalized(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols).union(.controlCharacters)
        for u in s.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch u.value {
            case 0x064B...0x065F, 0x0670, 0x0640, 0x200B...0x200F, 0x061C: continue
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append("ا")
            case 0x0649, 0x0626: out.append("ي")
            case 0x0629: out.append("ه")
            case 0x0624: out.append("و")
            default: if !skip.contains(u) { out.append(u) }
            }
        }
        return String(out)
    }

    /// True when every script run of `text` shows in the OCR lines (wrapped lines and mixed directions allowed).
    static func shows(_ text: String, in lines: [String]) -> Bool {
        let screen = normalized(lines.joined())
        return runs(text).map { normalized($0.text) }.filter { !$0.isEmpty }.allSatisfy { screen.contains($0) }
    }

    // MARK: Saved maps

    private struct Saved: Codable { var version: Int; var layouts: [Layout] }
    static var file: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("keyboard-layouts.json")
    }
    static func decode(_ data: Data) -> [Script: Layout] {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == version else { return [:] }
        return Dictionary(saved.layouts.filter { $0.version == version }.map { ($0.script, $0) }, uniquingKeysWith: { _, b in b })
    }
    static func encode(_ layouts: [Script: Layout]) -> Data? {
        try? JSONEncoder().encode(Saved(version: version, layouts: Script.allCases.compactMap { layouts[$0] }))
    }
    /// The learned maps (none until Keyboard check ran).
    static func load() -> [Script: Layout] {
        guard let file, let data = try? Data(contentsOf: file) else { return [:] }
        return decode(data)
    }
    /// Keeps `layout`, replacing an earlier map of the same script.
    static func save(_ layout: Layout) {
        var all = load(); all[layout.script] = layout
        if let file, let data = encode(all) { try? data.write(to: file, options: .atomic) }
    }
}
