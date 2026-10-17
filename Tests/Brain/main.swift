import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Offline checks for the fast agent's pure parts (ported from esp32-iphone-agent).
@main enum BrainChecks {
    static var checks = 0
    static func check(_ ok: Bool, _ name: String) {
        guard ok else { fatalError("FAIL: \(name)") }
        checks += 1
    }
    static func fails(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: \(name) must throw") } catch { checks += 1 }
    }

    static func jpeg(_ fill: (Int, Int) -> UInt8, w: Int = 120, h: Int = 260) -> Data {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v = fill(x, y); px[(y * w + x) * 4] = v; px[(y * w + x) * 4 + 1] = v; px[(y * w + x) * 4 + 2] = v } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Opening an app without a model: goal parsing, Home Screen label matching with OCR noise, icon tap point.
    static func fastPathChecks() {
        func open(_ goal: String) -> (String, Bool)? { FastPaths.opening(goal: goal).map { ($0.target.id, $0.onlyOpen) } }
        check(open("Open WhatsApp")! == ("whatsapp", true) && open("open my whatsapp app please.")! == ("whatsapp", true), "open only")
        check(open("Launch the Settings app")! == ("settings", true) && open("go to Photos")! == ("photos", true), "other verbs")
        check(open("Open WhatsApp and text Ali hi")! == ("whatsapp", false), "open then more")
        check(open("open whatsapp, then call mom")! == ("whatsapp", false) && open("Open Notes to write milk")! == ("notes", false), "connectors")
        check(open("open WhatsApp chat with Abdullah")! == ("whatsapp", false), "extra words keep the actor")
        check(open("افتح واتساب")! == ("whatsapp", true) && open("افتح لي الإعدادات")! == ("settings", true), "Arabic alias")
        check(FastPaths.opening(goal: "افتح واتساب")!.arabic && !FastPaths.opening(goal: "open whatsapp")!.arabic, "Arabic name flagged")
        check(open("افتح واتساب وارسل مرحبا لعبدالله")! == ("whatsapp", false), "Arabic open then more")
        check(open("Open Google Maps")! == ("googlemaps", true), "longest name wins")
        check(open("Send hi to Ali on WhatsApp") == nil && open("type hi in Arabic to him") == nil, "not an opening goal")
        check(open("open bluetooth") == nil && open("open the moon") == nil, "no Home Screen icon or unknown app")
        check(open("open wifi settings")! == ("settings", false), "Settings, then the actor finds Wi-Fi")
        check(open("Open WhatsApp and message Abdullah Al Rafai مرحبا")! == ("whatsapp", false)
              && open("Open WhatsApp [the app the user asked for]")! == ("whatsapp", false), "device matrix goals keep the actor")
        check(open("send it [the user confirmed sending]") == nil && open("اكتب له مرحبا [the person whose chat is open]") == nil,
              "call follow-ups skip the open path")

        func el(_ text: String, _ x: Double, _ y: Double) -> ScreenElement {
            ScreenElement(id: text, text: text, box: CGRect(x: x - 0.06, y: y, width: 0.12, height: 0.012))
        }
        let wa = AppLauncher.target(id: "whatsapp")!, mail = AppLauncher.target(id: "mail")!, settings = AppLauncher.target(id: "settings")!
        let home = [el("9:41", 0.15, 0.02), el("Calendar", 0.15, 0.2), el("WhatsApp is great", 0.4, 0.3),
                    el("Whats App", 0.62, 0.2), el("MaiI", 0.38, 0.32), el("Search", 0.5, 0.86)]
        check(FastPaths.label(for: wa, in: home)?.text == "Whats App", "spaced label matches, a sentence does not")
        check(FastPaths.label(for: mail, in: home)?.text == "MaiI", "one-letter OCR error")
        check(FastPaths.label(for: settings, in: home) == nil, "missing app")
        check(FastPaths.label(for: wa, in: [el("WhatsApq", 0.5, 0.5), el("WhatsApp", 0.2, 0.6)])?.text == "WhatsApp", "exact beats fuzzy")
        check(FastPaths.label(for: AppLauncher.target(id: "notes")!, in: [el("Notes", 0.2, 0.2)]) != nil
              && FastPaths.label(for: AppLauncher.target(id: "maps")!, in: [el("Mail", 0.2, 0.2)]) == nil, "two letters off is another app")
        check(FastPaths.label(for: AppLauncher.target(id: "safari")!, in: [el("Saﬁri", 0.2, 0.2)]) != nil, "ligature folded")
        check(FastPaths.label(for: settings, in: [el("الإعدادات", 0.2, 0.2)]) != nil
              && FastPaths.label(for: wa, in: [el("واتسأب", 0.2, 0.2)]) != nil, "Arabic label, alef forms joined")
        check(FastPaths.label(for: AppLauncher.target(id: "x")!, in: [el("Xe", 0.2, 0.2)]) == nil, "short names match exactly")
        check(FastPaths.searchPill(home)?.text == "Search" && FastPaths.searchPill([el("Search", 0.5, 0.1)]) == nil, "search pill above the dock")
        check(FastPaths.distance("whatsapp", "whatsapq", limit: 1) == 1 && FastPaths.distance("abc", "abcdef", limit: 1) == 2, "bounded distance")

        let p = FastPaths.iconPoint(label: CGRect(x: 0.55, y: 0.25, width: 0.14, height: 0.012))
        check(abs(p.x - 0.62) < 1e-9 && abs(p.y - (0.25 - FastPaths.iconLift)) < 1e-9, "icon above its label")
        check(FastPaths.iconLift > 0.03 && FastPaths.iconLift < 0.06, "lift inside a ~64 pt icon on a ~874 pt screen")
        check(FastPaths.iconPoint(label: CGRect(x: 0.1, y: 0.04, width: 0.1, height: 0.01)).y == 0.03, "never above the screen")
    }

    /// The task brief: parsing the model's JSON (good, partial, garbage), the actor's Brief block, the app it names,
    /// the question a call asks and the answer it speaks.
    static func briefChecks() {
        let good = """
        Sure, here it is:
        ```json
        {"intent": "Search the web for the best coffee in Riyadh", "app": "safari",
         "steps": ["1. Open Safari", "2. Tap the address bar", "Type the query and press Enter", "Read the results"],
         "text": ["best coffee shops in Riyadh"], "query": "best coffee shops in Riyadh", "deliverable": "answer",
         "done_when": "Search results are shown", "confirm_before": [], "ask": null}
        ```
        """
        let b = BrainBrief.parse(good)!
        check(b.intent.hasPrefix("Search the web") && b.app == "safari" && b.query == "best coffee shops in Riyadh", "brief fields")
        check(b.steps.count == 4 && b.steps[0] == "Open Safari" && b.steps[1] == "Tap the address bar", "step numbers stripped")
        check(b.deliverable == .answer && b.confirmBefore.isEmpty && b.ask == nil && b.doneWhen == "Search results are shown", "deliverable, no ask")
        check(b.target?.id == "safari", "brief app maps to the catalog")

        let arabic = BrainBrief.parse(#"{"intent": "Type hi in Arabic in the open chat", "app": "WhatsApp", "text": "مرحبا", "confirm_before": "send, Post", "deliverable": "ACTION"}"#)!
        check(arabic.text == ["مرحبا"] && arabic.query == nil && arabic.deliverable == .action, "partial brief: one text string, no query")
        check(arabic.confirmBefore == ["send", "post"] && arabic.steps.isEmpty && arabic.doneWhen.isEmpty, "confirm list from a string")
        check(arabic.target?.id == "whatsapp" && BrainBrief(app: "واتساب").target?.id == "whatsapp", "app by name or Arabic alias")
        check(BrainBrief(app: "wifi").target?.id == "settings" && BrainBrief(app: "moon").target == nil && BrainBrief(app: nil).target == nil, "no icon goes to Settings; unknown app")
        check(BrainBrief.parse(#"{"intent": "Call him", "app": "null", "query": "none", "ask": "Who should I call?"}"#)?.ask == "Who should I call?"
              && BrainBrief.parse(#"{"intent": "x", "app": "null"}"#)?.app == nil, "null words are nil")
        check(BrainBrief.parse("I can't help with that") == nil && BrainBrief.parse("{not json}") == nil
              && BrainBrief.parse("{}") == nil && BrainBrief.parse(#"{"app": "safari"}"#) == nil && BrainBrief.parse("") == nil, "garbage gives no brief")
        check(BrainBrief.parse(#"{"steps": ["a","b","c","d","e","f","g","h"], "text": [1, "ok"]}"#).map { $0.steps.count == 6 && $0.text == ["ok"] } == true, "steps capped, non-strings dropped")

        // A bad brief can only add caution: steps and done conditions that send, pay or delete are dropped.
        let pushy = BrainBrief.parse(#"{"intent": "Say hi to Ahmed", "steps": ["Open the chat", "Type مرحبا", "Tap Send", "Pay the invoice"], "text": ["مرحبا"], "done_when": "The message is sent", "confirm_before": []}"#)!
        check(pushy.steps == ["Open the chat", "Type مرحبا"] && pushy.doneWhen.isEmpty && !pushy.block.lowercased().contains("send"), "irreversible steps dropped")
        check(BrainBrief.risky("Tap Send") && BrainBrief.risky("Delete the photo") && !BrainBrief.risky("Tap the address bar")
              && !BrainBrief.risky("Read the results"), "irreversible actions")

        // "Open WhatsApp" stays model-free: no brief. Anything more, or a preview, gets one.
        check(!BrainBrief.needed(goal: "Open WhatsApp", previewOnly: false) && BrainBrief.needed(goal: "Open WhatsApp", previewOnly: true)
              && BrainBrief.needed(goal: "open Safari and search that thing", previewOnly: false)
              && BrainBrief.needed(goal: "type hi to him in Arabic", previewOnly: false), "brief only when the goal is more than opening an app")

        // The block the actor reads.
        let block = b.block
        check(block.hasPrefix("Intent: Search the web") && block.contains("Steps:\n1. Open Safari\n2. Tap the address bar"), "block intent and steps")
        check(block.contains("Search query: \"best coffee shops in Riyadh\""), "block query")
        check(block.contains("The user wants an answer") && !block.contains("Needs the user's OK"), "answer deliverable, nothing to confirm")
        check(arabic.block.contains("Type exactly: \"مرحبا\"") && arabic.block.contains("Needs the user's OK first: send, post")
              && !arabic.block.contains("answer"), "exact Arabic text and confirm in the block")
        let prompt = BrainPrompts.actorPrompt(goal: "Open Safari and search that thing", context: "", plan: "", history: [], brief: block)
        check(prompt.hasPrefix("Goal: Open Safari and search that thing\n\nBrief:\nIntent: ") && !prompt.contains("(none: act straight")
              && prompt.hasSuffix("Recent actions:\n(none)\n\nNext action?"), "the brief replaces the plan placeholder")
        let planned = BrainPrompts.actorPrompt(goal: "g", context: "", plan: "1. Tap Send", history: [], brief: "Intent: x")
        check(planned.contains("Brief:\nIntent: x\n\nPlan:\n1. Tap Send\n\nRecent actions:"), "brief, then a written plan")
        check(BrainPrompts.plannerPrompt(goal: "g", context: "", stuck: "stuck", brief: "Intent: x") == "Goal: g\n\nBrief:\nIntent: x\n\nstuck", "planner gets the brief")
        check(BrainPrompts.actor.contains("Brief's search query (not the user's words)") && BrainPrompts.actor.contains("Brief's text"), "research and exact-text rules")

        // The brief's own prompt: the time, the request verbatim and the context.
        let when = Date(timeIntervalSince1970: 1_792_000_000)
        let asked = BrainBrief.prompt(goal: "search that thing", context: "Context so far (…):\n1. \"what is a flat white\" -> done", now: when, locale: "ar-SA")
        check(asked.hasPrefix("Now: ") && asked.contains("2026") && asked.contains("phone language ar-SA") && asked.contains("Context so far")
              && asked.hasSuffix("Request: search that thing"), "brief prompt")
        check(!BrainBrief.prompt(goal: "g", context: "").contains("Context") && BrainBrief.system.contains("whatsapp, settings"), "no context; app ids listed")

        // What a call speaks: the question as a question; the answer without its label, kept short.
        check(BrainBrief.question("Which Abdullah do you mean") == "Which Abdullah do you mean?" && BrainBrief.question("أي عبدالله؟") == "أي عبدالله؟", "question mark")
        check(BrainBrief.answer("ANSWER: Tomorrow in Riyadh: sunny, high 34°C, low 22°C.") == "Tomorrow in Riyadh: sunny, high 34°C, low 22°C.", "answer label stripped")
        check(BrainBrief.answer("Answer - Brew92 and Camel Step\nare top rated.") == "Brew92 and Camel Step are top rated.", "answer on one line")
        let long = BrainBrief.answer(String(repeating: "word ", count: 120))
        check(long.count <= 401 && long.hasSuffix("…"), "long answers clipped on a word")
        check(b.summary.contains("search \"best coffee shops in Riyadh\"") && b.summary.contains("answer back"), "step log summary")
    }

    static func main() throws {
        // DO lines: several actions per reply, capped at 6; the thought lands on the first.
        let reply = """
        THINK: Tick the days.
        DO: tap 100 200
        DO: tap 110 210 precise
        DO: type hello world
        DO: key cmd+a
        DO: swipe 500 800 500 300
        DO: path 10 20 30 40 50 60
        DO: home
        """
        let acts = try BrainActions.parseActions(reply)
        check(acts.count == 6, "multi-DO capped at 6")
        check(acts[0]["thought"]?.str == "Tick the days." && acts[0]["x"]?.int == 100 && acts[0]["y"]?.int == 200, "first tap and thought")
        check(acts[1]["precise"]?.bool == true && acts[0]["precise"] == nil, "tap precise")
        check(acts[2]["text"]?.str == "hello world" && acts[3]["combo"]?.str == "cmd+a", "type and key text")
        check(acts[4]["y2"]?.int == 300, "swipe args")
        check(BrainActions.points(acts[5]) == [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 60)], "path pairs")
        check(BrainActions.pointerPath(acts[0]) == [CGPoint(x: 0.1, y: 0.2)], "pointer path of a tap")
        check(BrainActions.key(acts[0]) == ["action": .str("tap"), "x": .int(100), "y": .int(200)], "action key drops the thought")
        check(try BrainActions.parseCommand("done The alarm is set")["answer"]?.str == "The alarm is set", "done answer")
        check(try BrainActions.parseCommand("circle 500 500 100")["r"]?.int == 100, "circle")
        fails("path with an odd count") { _ = try BrainActions.parseCommand("path 1 2 3") }
        fails("tap without numbers") { _ = try BrainActions.parseCommand("tap here") }
        fails("unknown action") { _ = try BrainActions.parseCommand("jump 1 2") }
        fails("reply without DO") { _ = try BrainActions.parseActions("THINK: nothing") }
        check(BrainActions.parsePlan("  1. Open Clock\n2. Add alarm \n") == "1. Open Clock\n2. Add alarm", "plain plan")
        check(BrainActions.parsePlan("EN: 1. Open Clock ZH: x") == "1. Open Clock", "EN part of a plan")
        check(PyJSON.dumps(BrainActions.key(acts[0])) == #"{"action": "tap", "x": 100, "y": 200}"#, "history JSON format")

        // Board text commands, as BrainPointer sends them.
        let commands: [(String, BrainCommand)] = [
            ("home", .home), ("move 12 -30", .move(12, -30)), ("press", .press), ("release", .release),
            ("click", .click), ("scroll -3 0", .scroll(-3, 0)), ("scroll 4", .scroll(4, 0)),
            ("type Hello, world", .type("Hello, world")), ("type  two  spaces", .type(" two  spaces")),
            ("key cmd+a", .key("cmd+a")), ("homescreen", .homeScreen), ("MOVE 1 2", .move(1, 2)),
        ]
        for (line, want) in commands { check(try BrainCommand.parse(line) == want, "parse \(line)") }
        for bad in ["ping", "move 1", "move a b", "key", "home now", "", "stream on"] {
            fails("parse \(bad)") { _ = try BrainCommand.parse(bad) }
        }

        // ProbeFit: landed = 0.0025 * units + 0.01 is recovered from synthetic probes.
        let samples = [60.0, 200, 120, 300, 260].map { ($0, 0.0025 * $0 + 0.01) }
        guard let line = ProbeFit.line(samples) else { fatalError("FAIL: probe line") }
        check(abs(line.a - 0.0025) < 1e-9 && abs(line.b - 0.01) < 1e-9 && line.rms < 1e-9, "probe line recovered")
        check(line.units(for: 0.51) == 200, "units for a fraction")
        check(ProbeFit.line([(10, 0.1), (10, 0.2)]) == nil && ProbeFit.line([(10, 0.5), (20, 0.4)]) == nil, "degenerate lines")
        check(ProbeFit.throughHome((60, 0.15))?.a == 0.0025, "line through home")
        check(!ProbeFit.usable(0.99) && !ProbeFit.usable(0.01) && ProbeFit.usable(0.5), "edge taps dropped")
        let seed = ProbeFit.seed(offset: 0.03)
        check(seed.count == 2 && seed[0] == (0.2, 0.23) && abs(seed[1].1 - 0.83) < 1e-12, "seed offset")

        // FrameVision: identical frames did not change; a new element did.
        let blank = jpeg { _, _ in 230 }
        check(!FrameVision.changed(blank, blank), "identical frames unchanged")
        let box = jpeg { x, y in (40..<80).contains(x) && (100..<140).contains(y) ? 20 : 230 }
        check(FrameVision.changed(blank, box), "new box changed")
        check(FrameVision.changed(nil, blank), "missing frame counts as changed")

        // Fast-agent actions as the app's UI and approvals see them.
        func mapped(_ line: String) throws -> AgentAction { BrainActions.agentAction(try BrainActions.parseActions(line)[0]) }
        let tap = try mapped("THINK: Open Clock.\nDO: tap 250 750")
        check(tap.kind == .tap && tap.x == 0.25 && tap.y == 0.75 && tap.reason == "Open Clock.", "tap maps with its thought")
        let swipe = try mapped("DO: swipe 500 800 500 300")
        check(swipe.kind == .drag && swipe.x2 == 0.5 && swipe.y2 == 0.3 && swipe.reason == "Next step of the plan", "swipe maps to drag")
        let path = try mapped("DO: path 100 100 200 200 300 400")
        check(path.kind == .drag && path.x == 0.1 && path.y2 == 0.4, "path maps first to last point")
        check(try mapped("DO: circle 500 500 100").x == 0.6, "circle starts at its edge")
        check(try mapped("DO: type hi").text == "hi" && mapped("DO: key cmd+a").text == "cmd+a" && mapped("DO: key cmd+a").kind == .press_key, "type and key")
        check(try mapped("DO: home").kind == .press_key && mapped("DO: home").text == "home", "home maps to the Home key")
        check(try mapped("DO: back").x == 0.005 && mapped("DO: back").x2 == 0.6, "back is the edge swipe")
        check(try mapped("DO: wait").kind == .wait && mapped("DO: wait").seconds == 1, "wait")
        check(try mapped("DO: done Alarm set").kind == .finish && mapped("DO: done Alarm set").reason == "Alarm set", "done answer")
        check(try mapped("DO: fail No such contact").kind == .ask_user && mapped("DO: fail No such contact").reason == "No such contact", "fail asks the user")
        check(try mapped("DO: tap 1500 -20").x == 1 && mapped("DO: tap 1500 -20").y == 0, "coordinates clamped to the screen")

        // Old saved settings (engine picker, tools, step interval, Home mapping) still decode; Bedrock is chat only.
        let old = #"{"endpoint":"https://openrouter.ai/api/v1/chat/completions","model":"openai/gpt-6-luna","jsonMode":true,"legacyTokenLimit":false,"maxSteps":25,"startDelay":5,"stepInterval":1,"previewOnly":false,"confirmEachStep":false,"imageMaxSide":1280,"decisionEngine":"jev","toolsOnly":true,"systemToolsEnabled":true,"homeMappedPeripheralID":"x"}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(old.utf8))
        check(decoded.model == "openai/gpt-6-luna" && decoded.maxSteps == 25 && !decoded.usesBedrock, "old settings decode")
        var bedrock = AgentSettings(); bedrock.endpoint = "https://bedrock-runtime.us-east-1.amazonaws.com/model"
        check(bedrock.usesBedrock && AgentSettings.isBedrock(" https://BEDROCK-runtime.eu-west-1.amazonaws.com/x "), "Bedrock endpoints are recognized")

        // Probe calibrations (version 3) need 4 fit samples and one check; every other gate still applies.
        var probe = PointerCalibration(screenWidth: 402, screenHeight: 874, gainX: 1.6, gainY: 1.6, originX: 2, originY: 3,
            validationError: 4, peripheralID: "stick", createdAt: Date(), movementVersion: PointerMotion.profileVersion,
            calibrationVersion: CalibrationSolver.probeVersion, fitSampleCount: 4,
            validationSampleCount: 1, validationRMS: 3, returnDrift: 4)
        check(probe.usable, "probe calibration usable")
        probe.fitSampleCount = 3
        check(!probe.usable, "probe calibration needs 4 samples")
        probe.fitSampleCount = 6; probe.validationError = 9
        check(!probe.usable, "probe calibration check error gate")
        probe.validationError = 4; probe.movementVersion = 6
        check(!probe.usable, "old motion profile needs recalibration")
        check(PointerMotion.reportCount(x: 250, y: 0) == 10 && PointerMotion.reportInterval == 0.020, "fast pace 25 counts per 20 ms")

        // Acting and finishing in one reply: only after predictable gestures, and the last one must change the screen.
        let early = BrainActions.earlyDone(try BrainActions.parseActions("THINK: WhatsApp is in the dock.\nDO: tap 120 940\nDO: done WhatsApp is open\nDO: tap 1 1"))
        check(early.count == 2 && early[0]["verify"] == .bool(true) && early[1]["action"]?.str == "done", "tap then done keeps done, verifies the tap")
        check(BrainActions.key(early[0]) == ["action": .str("tap"), "x": .int(120), "y": .int(940)], "verify is bookkeeping")
        let typed = BrainActions.earlyDone(try BrainActions.parseActions("DO: type hi\nDO: key enter\nDO: done Sent"))
        check(typed.count == 2 && !typed.contains { $0["action"]?.str == "done" }, "done after typing is dropped")
        let alone = BrainActions.earlyDone(try BrainActions.parseActions("DO: done Already open\nDO: tap 1 1"))
        check(alone.count == 2 && alone[0]["verify"] == nil, "done first is left as is")
        let homeTap = BrainActions.earlyDone(try BrainActions.parseActions("DO: home\nDO: tap 500 500\nDO: done Open"))
        check(homeTap.count == 3 && homeTap[1]["verify"] == .bool(true) && homeTap[0]["verify"] == nil, "only the last gesture verifies")

        // Step timings in the log detail, never in the answer.
        var timed = try BrainActions.parseActions("THINK: Open it.\nDO: tap 100 100")[0]
        timed["timing"] = .str("model 1.4 s")
        check(BrainActions.agentAction(timed).reason == "Open it. · model 1.4 s" && BrainActions.key(timed)["timing"] == nil, "timing in the reason only")
        var answer = try BrainActions.parseActions("DO: done WhatsApp is open")[0]
        answer["timing"] = .str("model 1.4 s")
        check(BrainActions.agentAction(answer).reason == "WhatsApp is open", "done answer without timing")
        check(BrainTrace.format([("actor", 1.42), ("home", 0.48), ("move", 0.3), ("move", 0.31), ("settle", 0.01)])
              == "model 1.4 s, home 0.5 s, move 0.6 s", "trace summary sums and drops tiny phases")
        check(BrainTrace.format([]) == "", "empty trace summary")

        // Homing to the corner nearest the target; units still count from the top-left.
        check(PointerCorner.signs(0.1, 0.93) == (-1, 1) && PointerCorner.signs(0.8, 0.2) == (1, -1) && PointerCorner.signs(0.5, 0.5) == (1, 1), "nearest corner")
        check(PointerCorner.command(-1, -1) == "home" && PointerCorner.command(-1, 1) == "home -1 1", "corner command")
        check(PointerCorner.origin(-1, edgeFix: 0.99, span: 500) == 0 && PointerCorner.origin(1, edgeFix: 0.99, span: 500) == 495, "corner origin units")
        check(try BrainCommand.parse("home -1 1") == .homeCorner(-1, 1) && BrainCommand.parse("home -1 -1") == .home, "parse corner home")
        for bad in ["home 2 1", "home 1", "home 0 1"] { fails("parse \(bad)") { _ = try BrainCommand.parse(bad) } }
        // From the bottom-left corner a dock target is a short move, landing where the top-left home would aim.
        let spanH = 546, target = Int((0.93 * Double(spanH)).rounded())
        let fromBottom = target - PointerCorner.origin(1, edgeFix: 1, span: spanH)
        check(fromBottom == -38 && abs(fromBottom) < target / 10, "dock move from the bottom corner is short")

        fastPathChecks()
        briefChecks()
        keyboardChecks()
        print("PASS: \(checks) fast-agent parser, command, probe-fit and frame checks")
    }

    /// Typing by learned keyboards: script runs, plans across sources, source detection from key labels, checks.
    static func keyboardChecks() {
        typealias K = KeyboardLayouts
        typealias Key = KeyboardLayouts.Key
        // Script runs: neutral characters join the run they sit in.
        check(K.runs("Hi مهند!") == [.init(script: .latin, text: "Hi "), .init(script: .arabic, text: "مهند!")], "runs split at the script change")
        check(K.runs("12 ok") == [.init(script: .latin, text: "12 ok")] && K.runs("123")[0].script == nil && K.runs("").isEmpty, "neutral runs")
        check(K.script("é") == .latin && K.script("؟") == .arabic && K.script("7") == nil && K.script("👍") == nil, "character scripts")

        // Apple's Arabic hardware layout as seen on the device: a→ش s→س i→ه t→ف n→ر k→ن g→ل l→م h→ا d→ي.
        let seen: [(Character, String)] = [("a", "ش"), ("s", "س"), ("i", "ه"), ("t", "ف"), ("n", "ر"), ("k", "ن"), ("g", "ل"),
                                           ("l", "م"), ("h", "ا"), ("d", "ي"), ("m", "ة"), ("b", "لا")]
        var samples: [(Key, String)] = seen.map { (Key(0, UInt8($0.0.asciiValue! - 97 + 4)), $0.1) }
        samples += [(Key(0, 0x1E), "1"), (Key(2, 0x38), "؟"), (Key(0, 0x38), "/"), (Key(2, 0x04), "ِ")]
        let arabic = K.learn(samples, at: Date(timeIntervalSince1970: 0))!
        check(arabic.script == .arabic && arabic.keys["ش"] == Key(0, 4) && arabic.keys["لا"] == Key(0, 5), "learned Arabic map")
        check(K.learn([(Key(0, 4), "a"), (Key(0, 5), "b")]) == nil, "too few letters learn nothing")
        let latinSamples = (0..<26).map { (Key(0, UInt8(4 + $0)), String(UnicodeScalar(UInt8(97 + $0)))) }
        check(K.learn(latinSamples)?.script == .latin, "Latin detected from the letters")
        // The device's wrong output: English keys typed while Arabic was active.
        check(K.render("talking".map { K.builtinUS.keys[String($0)]! }, in: arabic) == "فشمنهرل", "talking → فشمنهرل")

        // Plans: letters need their source; neutral characters stay put when the active map has them.
        let layouts: [K.Script: K.Layout] = [.latin: K.builtinUS, .arabic: arabic]
        let mixed = try! K.plan("Hi شمس 1?", layouts: layouts, active: .latin)
        check(mixed.map(\.source) == [.latin, .arabic, .latin] && mixed.map(\.text) == ["Hi ", "شمس 1", "?"], "mixed plan")
        check(mixed[0].keys == [Key(2, 11), Key(0, 12), Key(0, 0x2C)] && mixed[1].keys.first == Key(0, 4), "plan keys")
        check(try! K.plan("1 شمس", layouts: layouts, active: nil).map(\.source) == [.arabic], "leading digits follow the next letter")
        check(try! K.plan("لا", layouts: layouts, active: .arabic)[0].keys == [Key(0, 5)], "a two-letter key")
        check(try! K.plan("ok", layouts: [.latin: K.builtinUS], active: .arabic).map(\.source) == [.latin], "English needs no learned map")
        do { _ = try K.plan("مرحبا", layouts: [.latin: K.builtinUS], active: .latin); check(false, "unlearned Arabic must throw") }
        catch { check(error as? K.PlanError == .unlearned(.arabic) && (error as! K.PlanError).message.contains("Run Keyboard check"), "unlearned Arabic") }
        do { _ = try K.plan("hi 👍", layouts: layouts, active: .latin); check(false, "emoji must throw") }
        catch { check(error as? K.PlanError == .untypable("👍"), "emoji is untypable") }

        // The active source from OCR of the keyboard (labels below 0.6 count; app text above does not).
        func label(_ t: String, _ y: Double) -> (text: String, box: CGRect) { (t, CGRect(x: 0.1, y: y, width: 0.05, height: 0.03)) }
        check(K.activeSource(["ض", "ص", "ث", "ق", "ع"].map { label($0, 0.7) }) == .arabic, "Arabic key labels")
        check(K.activeSource([label("q w e r t y", 0.7), label("A", 0.78), label("مرحبا بك في التطبيق", 0.5)]) == .latin, "Latin key labels")
        check(K.activeSource([label("QWERTYUIOP", 0.7), label("asdfghjkl", 0.76)]) == .latin, "whole rows read as words")
        check(K.activeSource([label("شسيبلاتنمكة", 0.76)]) == .arabic, "an Arabic row as one word")
        check(K.activeSource([label("Chats", 0.95), label("Calls", 0.95), label("ض", 0.3), label("ص", 0.3), label("ث", 0.3)]) == nil, "no keyboard")
        check(K.activeSource([label("a", 0.7), label("b", 0.7), label("ض", 0.7), label("ص", 0.7)]) == nil, "unclear")

        // Checking what was typed: Arabic forms and spacing folded; the wrong-letter rendering is caught.
        check(K.normalized("أَهلاً  بِكَ") == "اهلابك" && K.normalized("Hi, Ali!") == "hiali" && K.normalized("مستشفى") == "مستشفي", "normalize")
        check(K.shows("Hello there", in: ["Hello", "there"]) && K.shows("مرحبا Sam", in: ["Sam مرحبآ"]), "typed text found")
        check(!K.shows("assistant", in: ["شسسهسفشرف"]) && K.shows("...", in: []), "wrong letters are not a match")

        // Saved maps round-trip with their version and date; another version is ignored.
        let data = K.encode(layouts)!
        check(K.decode(data) == layouts && K.decode(Data("{\"version\":0,\"layouts\":[]}".utf8)).isEmpty, "saved maps")
    }
}
