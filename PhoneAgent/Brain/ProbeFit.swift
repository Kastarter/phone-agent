// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation

/// Least-squares line through touch-probe samples: landed = a * units + b, per axis.
enum ProbeFit {
    struct Line: Equatable {
        var a: Double, b: Double
        var rms: Double  // residual, fraction of the screen

        /// Mouse units (from home) that land on screen fraction f.
        func units(for f: Double) -> Int { Int(((f - b) / a).rounded()) }
    }

    /// samples: (mouse units from home, landed screen fraction). Nil with fewer than two distinct points.
    static func line(_ samples: [(Double, Double)]) -> Line? {
        let n = Double(samples.count)
        guard samples.count >= 2 else { return nil }
        let mu = samples.map(\.0).reduce(0, +) / n, mf = samples.map(\.1).reduce(0, +) / n
        let variance = samples.map { pow($0.0 - mu, 2) }.reduce(0, +)
        guard variance > 1e-6 else { return nil }
        let a = samples.map { ($0.0 - mu) * ($0.1 - mf) }.reduce(0, +) / variance
        guard a > 0 else { return nil }
        let b = mf - a * mu
        let rms = sqrt(samples.map { pow($0.1 - (a * $0.0 + b), 2) }.reduce(0, +) / n)
        return Line(a: a, b: b, rms: rms)
    }

    /// One sample and no offset: the line through home (0, 0).
    static func throughHome(_ s: (Double, Double)) -> Line? {
        s.0 > 0 && s.1 > 0 ? Line(a: s.1 / s.0, b: 0, rms: 0) : nil
    }

    /// A tap at the very edge may be the pointer stuck there: useless for a fit.
    static func usable(_ f: Double) -> Bool { 0.02 < f && f < 0.98 }

    /// Two seed landings for BrainPointer's learned correction: no scale change, offset b (a fraction).
    static func seed(offset b: Double) -> [(Double, Double)] { [(0.2, 0.2 + b), (0.8, 0.8 + b)] }
}

/// Homing into the screen corner nearest the next target, so the pointer travels the short way. The pointer
/// clamps at the screen edge, so a corner is an exact position on both axes.
enum PointerCorner {
    /// -1 = left / top, +1 = right / bottom, for a target in screen fractions.
    static func signs(_ x: Double, _ y: Double) -> (Int, Int) { (x < 0.5 ? -1 : 1, y < 0.5 ? -1 : 1) }

    /// The corner's position in mouse units from the top-left home: 0 on a near axis; on a far axis the units the
    /// calibration would send from the top-left to land on the edge (fraction 1), i.e. fix(1) * span.
    static func origin(_ sign: Int, edgeFix: Double, span: Int) -> Int {
        sign < 0 ? 0 : Int((edgeFix * Double(span)).rounded())
    }

    /// The board command for that corner (plain "home" is the top-left homing the app always had).
    static func command(_ sx: Int, _ sy: Int) -> String { sx < 0 && sy < 0 ? "home" : "home \(sx) \(sy)" }
}
