// Run on macOS: compile with AgentModels.swift, MouseProtocol.swift, HIDKeyboard.swift and KeyboardLayouts.swift.
import Foundation

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try value() else { fatalError(label) }; checks += 1
}

try check(Array(MouseProtocol.packet(.report, sequence: 1, x: 20, y: 10)) == [1,1,1,0,0,20,10,0,0,0], "mouse vector")
try check(Array(MouseProtocol.packet(.click, sequence: 3, buttons: 1, delay: 3000)) == [1,2,3,0,1,0,0,0,184,11], "delay endian")
try check(Array(MouseProtocol.packet(.report, sequence: 65535, x: -127, y: 127))[2...6] == [255,255,0,129,127], "signed and sequence")
try check(MouseProtocol.packet(.report, sequence: 0, x: -900)[5] == 129, "clamp signed minimum")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,0,0]))?.ready == true, "old firmware ready")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,0,0]))?.keyboardAvailable == false, "old keyboard unavailable")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,3,1]))?.keyboardAvailable == true, "new keyboard ready")
try check(MouseProtocol.Status(Data([1,23,0,0,1,0,0,0]))?.ready == false, "suspended")
try check(MouseProtocol.Status(Data([1,15,1,0,1,0,0,0]))?.busy == true, "busy click")
try check(MouseProtocol.Status(Data([1,7])) == nil, "truncated status")
try check(MouseProtocol.Status(Data([2,7,0,0,1,0,0,0])) == nil, "unknown version")
try check(try HIDKeyboard.ascii("a").0 == 0 && HIDKeyboard.ascii("a").1 == 4, "lowercase")
try check(try HIDKeyboard.ascii("A").0 == 2 && HIDKeyboard.ascii("A").1 == 4, "uppercase shift")
try check(try HIDKeyboard.ascii("0").1 == 39, "zero usage")
try check(try HIDKeyboard.ascii("@").0 == 2 && HIDKeyboard.ascii("@").1 == 31, "shift two")
try check(try HIDKeyboard.ascii("\\").1 == 49, "backslash")
try check(try HIDKeyboard.key("select_all").0 == 8 && HIDKeyboard.key("select_all").1 == 4, "Command A")
do { _ = try HIDKeyboard.ascii("é"); fatalError("unsupported Unicode must fail") } catch { checks += 1 }
// Consumer control (AC Home) and key combos.
try check(Array(MouseProtocol.consumerPacket(sequence: 0x0102, usage: MouseProtocol.acHome)) == [1,6,2,1,0,0x23,0x02,0,0,0], "consumer packet")
try check(MouseProtocol.Operation.consumer.rawValue == 6, "consumer op")
let consumerStatus = MouseProtocol.Status(Data([1,7,0,0,1,0,31,1]))
try check(consumerStatus?.consumerAvailable == true && consumerStatus?.consumerSupported == true, "consumer ready")
let unsubscribed = MouseProtocol.Status(Data([1,7,0,0,1,0,23,1]))
try check(unsubscribed?.consumerAvailable == false && unsubscribed?.consumerSupported == true, "consumer not subscribed")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,31,0]))?.consumerAvailable == false, "consumer needs revision bit")
let oldStatus = MouseProtocol.Status(Data([1,7,0,0,1,0,7,1]))
try check(oldStatus?.consumerAvailable == false && oldStatus?.consumerSupported == false, "old firmware has no consumer")
try check(MouseProtocol.Status(Data([1,7,0,0,1,0,0,0]))?.consumerSupported == false, "oldest firmware has no consumer")
func combo(_ text: String) throws -> [UInt8] { let (m, k) = try HIDKeyboard.combo(text); return [m, k] }
try check((try? combo("cmd+h")) == nil && (try? combo("Command+Shift+H")) == nil, "cmd+h refused")
try check(try combo("cmd+a") == [8,4] && combo("Command+a") == [8,4], "cmd+a")
try check(try combo("esc") == [0,41], "esc")
try check(try combo("enter") == [0,40] && combo("return") == [0,40], "enter")
try check(try combo("cmd+shift+z") == [10,29], "cmd+shift+z")
try check(try combo("ctrl+space") == [1,44], "ctrl+space")
try check(try combo("A") == [2,4], "shifted letter")
for bad in ["cmd", "cmd+a+b", "", "cmd+shift", "cmd+nokey"] {
    do { _ = try HIDKeyboard.combo(bad); fatalError("combo \(bad) must fail") } catch { checks += 1 }
}
let calibration = PointerCalibration(screenWidth: 390, screenHeight: 844, gainX: 1, gainY: 1,
    originX: 0, originY: 0, validationError: 5, peripheralID: "device", createdAt: Date(),
    movementVersion: PointerMotion.profileVersion, calibrationVersion: CalibrationSolver.probeVersion,
    fitSampleCount: 4, validationSampleCount: 1, validationRMS: 5, returnDrift: 5)
try check(calibration.usable, "valid calibration")
var invalid = calibration; invalid.gainX = 0
try check(!invalid.usable, "zero gain invalid")
invalid = calibration; invalid.validationError = CalibrationSolver.maxValidationError + 1
try check(!invalid.usable, "bad accuracy invalid")
invalid = calibration; invalid.originX = .nan
try check(!invalid.usable, "NaN calibration invalid")
invalid = calibration; invalid.movementVersion = nil
try check(!invalid.usable, "legacy movement profile invalid")
invalid = calibration; invalid.calibrationVersion = 2
try check(!invalid.usable, "the old grid calibration needs redoing")
try check(PointerMotion.reportCount(x: 250, y: 0) == 10 && PointerMotion.reportCount(x: 0, y: 0) == 0, "report count at 25 counts per report")

print("PASS: \(checks) protocol, keyboard and calibration checks")

// --- Key pacing: firmware-timed key sequences and the per-key fallback -------------
func keyPacingChecks() throws {
    let keys: [(UInt8, UInt8)] = [(2, 11), (0, 8), (0, 15), (0, 15), (0, 18)]  // "Hello"
    let packet = Array(MouseProtocol.keySequencePacket(sequence: 0x0203, keys: keys[...]))
    try check(packet == [1, 7, 3, 2, 5, 12, 8, 2, 11, 0, 8, 0, 15, 0, 15, 0, 18], "key sequence packet")
    try check(packet.count % 2 == 1 && packet.count != 10 && packet.count != 14, "odd length never collides")
    let full = Array(repeating: (UInt8(0), UInt8(4)), count: MouseProtocol.keyBatchMax)
    try check(MouseProtocol.keySequencePacket(sequence: 1, keys: full[...]).count == 55, "full batch fits MTU 64")
    try check(Array(MouseProtocol.keySequencePacket(sequence: 9, keys: keys[1..<3], downMS: 20, upMS: 10)) == [1, 7, 9, 0, 2, 20, 10, 0, 8, 0, 15], "slice and custom timing")
    try check(MouseProtocol.keyBatchLimit(maximumWrite: 20) == 6 && MouseProtocol.keyBatchLimit(maximumWrite: 61) == 24 &&
              MouseProtocol.keyBatchLimit(maximumWrite: 512) == 24 && MouseProtocol.keyBatchLimit(maximumWrite: 7) == 1, "batch limit")
    try check(2 * MouseProtocol.keyBatchMax <= MouseProtocol.keyQueueSize, "two batches fit the board queue")
    try check(MouseProtocol.Status(Data([1,7,0,0,1,0,63,1]))?.keySequenceSupported == true, "key sequence bit")
    try check(MouseProtocol.Status(Data([1,7,0,0,1,0,31,1]))?.keySequenceSupported == false, "old firmware types per key")
    try check(MouseProtocol.Status(Data([1,7,0,0,1,0,63,0]))?.keySequenceSupported == false, "key sequence needs revision bit")
    func flat(_ r: [(UInt8, UInt8)]) -> [UInt8] { r.flatMap { [$0.0, $0.1] } }
    // "Hello": shift change releases, the double l releases, different keys roll over, ends released.
    try check(flat(HIDKeyboard.reports(keys)) == [2,11, 0,0, 0,8, 0,15, 0,0, 0,15, 0,18, 0,0], "fallback reports")
    try check(flat(HIDKeyboard.reports([(0, 4), (0, 4), (0, 4)])) == [0,4, 0,0, 0,4, 0,0, 0,4, 0,0], "repeats always released")
    try check(flat(HIDKeyboard.reports([(2, 4), (2, 5)])) == [2,4, 2,5, 0,0], "same shift rolls over")
    try check(HIDKeyboard.reports([]).isEmpty, "nothing to type")
    let sentence = "Hi Sam, I am the assistant you were talking to earlier today."
    let reports = HIDKeyboard.reports(sentence.map { try! HIDKeyboard.ascii($0) })
    print(String(format: "key pacing: %d chars -> %d fallback writes (%.2f/char, was 2.00 + 90 ms sleep); board-timed %d ms/char",
                 sentence.count, reports.count, Double(reports.count) / Double(sentence.count),
                 Int(MouseProtocol.keyDownMS) + Int(MouseProtocol.keyUpMS)))
}
try keyPacingChecks()
print("PASS: key pacing checks (\(checks) total)")

// --- Learned keyboard maps: the built-in US map types exactly what HIDKeyboard.ascii does -------------
func keyboardLayoutChecks() throws {
    let printable = (32...126).map { Character(UnicodeScalar(UInt8($0))) } + ["\n", "\t"]
    for c in printable {
        let (modifier, usage) = try HIDKeyboard.ascii(c)
        guard let step = try KeyboardLayouts.plan(String(c), layouts: [.latin: KeyboardLayouts.builtinUS], active: nil).first else { fatalError("no plan for \(c)") }
        try check(step.keys == [KeyboardLayouts.Key(modifier, usage)], "US map for \(c.debugDescription)")
    }
    try check(KeyboardLayouts.probeUsages.count == 48 && !KeyboardLayouts.probeUsages.contains(0x2C), "probed usages")
}
try keyboardLayoutChecks()
print("PASS: keyboard layout checks (\(checks) total)")
