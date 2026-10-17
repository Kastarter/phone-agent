// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Their board's text commands, run over our encrypted BLE mouse and keyboard protocol.
@MainActor final class BrainDevice: HIDDevice {
    let executor: MouseExecutor
    private var ble: BLETransport { executor.ble }
    private var generation: UUID
    private var linkCount = 0
    private var held: UInt8 = 0  // left button held by "press"

    init(executor: MouseExecutor) {
        self.executor = executor
        generation = executor.ble.pointerConnectionGeneration
    }

    var links: Int {
        if generation != ble.pointerConnectionGeneration {
            generation = ble.pointerConnectionGeneration; linkCount += 1; held = 0
        }
        return linkCount
    }
    var connected: Bool { ble.ready }

    func waitConnected(_ timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !ble.ready {
            if Date() > deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    @discardableResult func send(_ line: String) async throws -> String {
        switch try BrainCommand.parse(line) {
        case .home: try await executor.homePointer()
        case .homeCorner(let sx, let sy): try await homeCorner(sx, sy)
        case .move(let dx, let dy): try await move(dx, dy)
        case .press: try await ble.send(.report, buttons: 1); held = 1
        case .release: held = 0; await ble.release()
        case .click:
            try await ble.send(.click, buttons: 1)
            try await executor.sleep(0.07)
            try await ble.waitIdle()
        case .scroll(let v, _):
            guard ble.status?.bootMode != true else { throw AgentError.message("Scroll wheel isn't supported in system Boot mode") }
            try await ble.send(.report, buttons: held, wheel: max(-20, min(20, v)))
        case .type(let text): try await type(text)
        case .key(let combo):
            let (modifier, key) = try HIDKeyboard.combo(combo)
            try await executor.pressCombo(modifier, key)
        case .homeScreen:
            guard ble.consumerReady else { throw DeviceError(message: "err homescreen unsupported") }
            try await ble.homeScreen()
        }
        return "ok"
    }

    // MARK: Typing by keystrokes

    /// Where the fast agent reads the keyboard and taps its 🌐 key (set by AgentEngine; nil types blind).
    weak var screen: BrainScreen?
    var tapAt: ((Double, Double) async throws -> Void)?
    /// What the last "type" check found when the text did not show as intended; the step log carries it.
    private(set) var typeCheck: String?
    private var lastSource: KeyboardLayouts.Script?
    /// The 🌐 key, bottom-left on both the Latin and the Arabic keyboard (OCR can't read the globe).
    static let globe = (x: 0.097, y: 0.957)

    /// Types `text` by HID keystrokes (no clipboard: iOS refuses pasteboard writes while Phone Agent is in the
    /// background). Each script run is typed on its input source: the active one is read from the on-screen key
    /// labels, the 🌐 key switches it, and the keys come from the map Keyboard check learned for that source.
    private func type(_ raw: String) async throws {
        typeCheck = nil
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.isEmpty else { return }
        guard ble.keyboardReady else { throw DeviceError(message: "err the Bluetooth keyboard isn't ready") }
        var layouts = KeyboardLayouts.load()
        if layouts[.latin] == nil { layouts[.latin] = KeyboardLayouts.builtinUS }
        let shown = await BrainTrace.time("kbd detect") { await detectSource() }
        var active = shown ?? lastSource
        let steps: [KeyboardLayouts.Step]
        do { steps = try KeyboardLayouts.plan(text, layouts: layouts, active: active) }
        catch let e as KeyboardLayouts.PlanError { throw DeviceError(message: e.message) }
        for var step in steps {
            if shown != nil {
                if active != step.source { active = try await switchSource(to: step.source) }
            } else if let other = layouts[step.source == .latin ? .arabic : .latin] {
                // No on-screen keyboard to read: type the run's first word on the assumed source and check it.
                step = try await probeFirstWord(step, other: other)
            }
            if !step.keys.isEmpty {
                let started = brainNow()
                try await sendKeys(step.keys, latin: step.source == .latin)
                BrainTrace.mark("type", brainNow() - started, "\(step.text.count) chars \(step.source.name), \(ble.lastTyping?.summary ?? "")")
            }
            lastSource = step.source; active = step.source
        }
        await verify(text, steps: steps, layouts: layouts, keyboardShown: shown != nil)
    }

    /// Keystrokes from a map; Caps Lock flips Shift on Latin letters.
    private func sendKeys(_ keys: [KeyboardLayouts.Key], latin: Bool) async throws {
        let caps = latin && ble.status?.capsLock == true
        try await ble.typeKeys(keys.map { (caps && (4...29).contains($0.usage) ? $0.modifier ^ KeyboardLayouts.shift : $0.modifier, $0.usage) })
    }

    /// The source the on-screen keyboard shows, from its key labels (accurate OCR, which reads Arabic).
    private func detectSource() async -> KeyboardLayouts.Script? {
        guard let screen, screen.live, let jpeg = screen.fullJPEG else { return nil }
        let labels = await KeyboardOCR.read(jpeg, region: CGRect(x: 0, y: KeyboardLayouts.keyboardTop, width: 1, height: 1 - KeyboardLayouts.keyboardTop))
        return KeyboardLayouts.activeSource(labels)
    }

    /// Taps 🌐 until the keyboard shows `target` (up to 3 taps: there may be more than two keyboards).
    private func switchSource(to target: KeyboardLayouts.Script) async throws -> KeyboardLayouts.Script {
        guard let tapAt, let screen else { throw DeviceError(message: "err can't switch the keyboard to \(target.name): no pointer") }
        for attempt in 1...3 {
            let now = try await BrainTrace.time("kbd switch", "tap 🌐 \(attempt) for \(target.name)") { () async throws -> KeyboardLayouts.Script? in
                try await tapAt(Self.globe.x, Self.globe.y)
                await screen.settled(quiet: 0.12, least: 0.12, most: 0.8)
                return await detectSource()
            }
            if now == target { return target }
        }
        throw DeviceError(message: "err couldn't switch the keyboard to \(target.name) with the 🌐 key (bottom-left); switch it by hand")
    }

    /// The keyboard is hidden (a hardware keyboard can hide it): type the first word on the last known source and
    /// read it back. If it came out in the other source's letters, delete it, switch with Control-Space (the only
    /// way without the 🌐 key) and type it again. Returns the rest of the step.
    private func probeFirstWord(_ step: KeyboardLayouts.Step, other: KeyboardLayouts.Layout) async throws -> KeyboardLayouts.Step {
        guard let screen, screen.live else { return step }
        let chars = Array(step.text)
        let n = min(8, chars.firstIndex(where: \.isWhitespace) ?? chars.count)
        guard n > 0, step.keys.count >= n, chars.count == step.keys.count else { return step }  // multi-character keys: type it all
        let word = String(chars[..<n]), keys = Array(step.keys[..<n])
        let wrong = KeyboardLayouts.render(keys, in: other)
        for attempt in 0..<2 {
            try await BrainTrace.time("type", "first word, keyboard hidden") { try await sendKeys(keys, latin: step.source == .latin) }
            let lines = await readBack(screen)
            if KeyboardLayouts.shows(word, in: lines) || !KeyboardLayouts.shows(wrong, in: lines) {
                return KeyboardLayouts.Step(source: step.source, keys: Array(step.keys[n...]), text: String(chars[n...]))
            }
            try await ble.typeKeys(Array(repeating: (0, 0x2A), count: wrong.count))  // backspace what came out
            guard attempt == 0 else { break }
            try await BrainTrace.time("kbd switch", "Control-Space, keyboard hidden") {
                try await executor.pressCombo(1, 0x2C); try await executor.sleep(0.25)
            }
        }
        throw DeviceError(message: "err the keyboard is on \(other.script.name), not \(step.source.name), and the on-screen keyboard is hidden, so it can't be switched: show the keyboard or switch it by hand")
    }

    /// OCR of the settled screen above the keyboard.
    private func readBack(_ screen: BrainScreen, keyboardShown: Bool = false) async -> [String] {
        await screen.settled(quiet: 0.15, least: 0.1, most: 0.8)
        guard let jpeg = screen.fullJPEG else { return [] }
        return await KeyboardOCR.read(jpeg).filter { !keyboardShown || $0.box.midY < KeyboardLayouts.keyboardTop }.map(\.text)
    }

    /// Reads the field back; a mismatch goes in `typeCheck` (and the trace) so the model sees it.
    private func verify(_ text: String, steps: [KeyboardLayouts.Step], layouts: [KeyboardLayouts.Script: KeyboardLayouts.Layout],
                        keyboardShown: Bool) async {
        guard let screen, screen.live, !KeyboardLayouts.normalized(text).isEmpty else { return }
        let started = brainNow()
        let lines = await readBack(screen, keyboardShown: keyboardShown)
        guard !lines.isEmpty else { return }
        var note = ""
        if !KeyboardLayouts.shows(text, in: lines) {
            // Same keys on the other source: the text came out in the wrong letters.
            for step in steps {
                guard let other = layouts[step.source == .latin ? .arabic : .latin] else { continue }
                let wrong = KeyboardLayouts.render(step.keys, in: other)
                if KeyboardLayouts.shows(wrong, in: lines) {
                    note = "\"\(step.text.prefix(40))\" came out as \"\(wrong.prefix(40))\" (the keyboard was on \(other.script.name)); delete it and type again"
                    break
                }
            }
            if note.isEmpty { note = "the typed text was not found on screen; check the field before going on" }
            typeCheck = note
        }
        BrainTrace.mark("type verify", brainNow() - started, note.isEmpty ? "ok" : note)
    }

    /// The executor's homing slam (20 reports of 127 counts) toward any corner: the pointer clamps at both edges.
    private func homeCorner(_ sx: Int, _ sy: Int) async throws {
        let token = ble.beginPointerMotion()
        defer { ble.endPointerMotion(token) }
        let connection = ble.pointerConnectionGeneration
        do {
            try await ble.moveBuffered(x: sx * 127 * 20, y: sy * 127 * 20, buttons: held, reports: 20, intervalMS: 20)
            try await executor.sleep(0.08)
            guard ble.ready, ble.pointerConnectionGeneration == connection else { throw DeviceError(message: "The mouse connection changed") }
        } catch {
            if ble.pointerConnectionGeneration == connection { await ble.release() }
            held = 0
            throw error
        }
    }

    /// Relative counts at their pace: 25 counts per 20 ms report (~1250 counts/s), the button kept as held.
    /// Chunks stay under the firmware's 10000-count limit and its 127-count per-report step.
    private func move(_ dx: Int, _ dy: Int) async throws {
        let token = ble.beginPointerMotion()
        defer { ble.endPointerMotion(token) }
        var (x, y) = (dx, dy)
        while x != 0 || y != 0 {
            let cx = max(-9000, min(9000, x)), cy = max(-9000, min(9000, y))
            // The same report count as calibration probes (PointerMotion), so pointer acceleration matches the fit.
            let reports = max(1, PointerMotion.reportCount(x: cx, y: cy))
            try await ble.moveBuffered(x: cx, y: cy, buttons: held, reports: reports,
                                       intervalMS: Int((PointerMotion.reportInterval * 1000).rounded()))
            x -= cx; y -= cy
        }
    }
}

/// Apple Vision OCR that keeps single characters (keyboard key labels), unlike ScreenReader. Accurate mode with
/// Arabic first, since fast mode reads Latin only. Boxes are normalized to the whole image, top-left origin.
enum KeyboardOCR {
    static func read(_ jpeg: Data, region: CGRect? = nil) async -> [(text: String, box: CGRect)] {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [(text: String, box: CGRect)] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
            let languages = ["ar-SA", "en-US"].filter { supported.contains($0) }
            request.recognitionLanguages = languages.isEmpty ? ["en-US"] : languages
            // Vision's region is bottom-left origin; results are relative to it.
            let roi = region.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            request.regionOfInterest = roi
            guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { o in
                guard let text = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let b = o.boundingBox
                let full = CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height, width: b.width * roi.width, height: b.height * roi.height)
                return ScreenReader.topLeftBox(full).map { (text, $0) }
            }
        }.value
    }
}
