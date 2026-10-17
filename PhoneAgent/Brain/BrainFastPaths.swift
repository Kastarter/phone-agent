import Foundation
import CoreGraphics

/// Model-free shortcuts for the fast agent. Opening an app: read the Home Screen labels with Apple Vision and tap
/// the icon above the right one, or type the name into Home Screen search. The actor model only runs for the
/// rest of the goal, and not at all when the goal was just "open X".
enum FastPaths {
    /// The goal opens a catalog app first; `onlyOpen` when nothing else is asked; `spoken` is the name it used.
    struct Opening: Equatable {
        let target: LaunchTarget
        let onlyOpen: Bool
        let spoken: String
        var arabic: Bool { FastPaths.hasArabic(spoken) }
    }

    /// Screen fraction from the top of a Home Screen label's text to its icon's center. Icons are ~64 pt with the
    /// label ~4 pt under them on a 874 pt tall screen (~0.044); the icon spans about ±0.037 around it.
    static let iconLift = 0.045

    private static let verbs = #"^(?:(?:please|can you|could you|now)\s+)*(?:open|launch|start|run|go to|switch to|bring up|pull up|افتح|افتحي|شغل|شغلي|روح)\s+(?:(?:up|me|لي)\s+)?"#
    private static let connectors = #"\s*(?:,|;|\.|،|\band\b|\bthen\b|\bto\b|\bso\b|\bwhere\b|\bthere\b|\bثم\b)\s*"#
    private static let fillers: Set<String> = ["the", "my", "app", "application", "please", "for", "me", "now", "up", "a",
                                               "an", "quickly", "لي", "تطبيق", "برنامج", "الان", "الآن", "من", "فضلك"]

    /// "Open WhatsApp" → WhatsApp, only opening; "open whatsapp and text Ali" → WhatsApp, then the actor;
    /// "افتح واتساب" → WhatsApp. Settings deep links (Wi-Fi, Bluetooth) have no Home Screen icon.
    static func opening(goal: String) -> Opening? {
        let text = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = text.range(of: verbs, options: .regularExpression) else { return nil }
        let rest = String(text[verb.upperBound...])
        let clause = rest.range(of: connectors, options: .regularExpression).map { String(rest[..<$0.lowerBound]) } ?? rest
        let words = " " + clause.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression) + " "
        var best: (LaunchTarget, String)?
        for target in AppLauncher.catalog {
            for name in [target.name] + target.aliases where words.contains(" " + name.lowercased() + " ") {
                if name.count > (best?.1.count ?? 0) { best = (target, name) }
            }
        }
        guard let (target, spoken) = best, !["wifi", "bluetooth"].contains(target.id) else { return nil }
        let left = words.replacingOccurrences(of: " " + spoken.lowercased() + " ", with: " ")
            .split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        let extra = rest.count > clause.count && !rest.dropFirst(clause.count)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty
        return Opening(target: target, onlyOpen: left.isEmpty && !extra, spoken: spoken)
    }

    /// The label that names the app, exact first, then within OCR noise (one wrong letter, two for long names).
    static func label(for target: LaunchTarget, in elements: [ScreenElement]) -> ScreenElement? {
        matches(target, elements).first
    }

    /// Every label naming the app, best first.
    static func matches(_ target: LaunchTarget, _ elements: [ScreenElement]) -> [ScreenElement] {
        let keys = ([target.name] + target.aliases).map(fold).filter { !$0.isEmpty }
        let scored = elements.compactMap { e -> (ScreenElement, Int)? in
            let text = fold(e.text)
            let best = keys.map { key -> Int in
                let allowed = key.count >= 9 ? 2 : key.count >= 4 ? 1 : 0
                let d = distance(text, key, limit: allowed)
                return d <= allowed ? d : .max
            }.min() ?? .max
            return best == .max ? nil : (e, best)
        }
        return scored.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    /// Where to tap for the icon above a Home Screen label (screen fractions).
    static func iconPoint(label: CGRect) -> CGPoint {
        CGPoint(x: label.midX, y: max(0.03, Double(label.minY) - iconLift))
    }

    /// The iOS "Search" pill above the dock.
    static func searchPill(_ elements: [ScreenElement]) -> ScreenElement? {
        elements.first { ["search", "بحث"].contains(fold($0.text)) && $0.center.y > 0.7 && $0.center.y < 0.97 }
    }

    /// Lowercase letters and digits only: ligatures split, accents and Arabic vowel marks dropped, alef forms joined.
    static func fold(_ s: String) -> String {
        var t = s
        for (a, b) in ["ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl", "أ": "ا", "إ": "ا", "آ": "ا",
                       "ٱ": "ا", "ة": "ه", "ى": "ي", "ـ": ""] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return String(String.UnicodeScalarView(t.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.filter { !CharacterSet.nonBaseCharacters.contains($0) }))
    }

    static func hasArabic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }

    /// Levenshtein distance, giving up (limit + 1) once it is over `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0], low = i
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur; low = min(low, row[j])
            }
            if low > limit { return limit + 1 }
        }
        return row[b.count]
    }
}

#if canImport(UIKit)
import UIKit

extension FastPaths {
    @MainActor private static var inBackground: Bool { UIApplication.shared.applicationState == .background }

    /// Opens the app from the Home Screen that is in front now (Phone Agent just left at `since`): the label on
    /// this page, else Home Screen search. True once a new screen shows with Phone Agent still in the background.
    @MainActor static func openApp(_ open: Opening, pointer: Gestures, screen: BrainScreen, since: Double,
                                   check: () throws -> Void) async throws -> Bool {
        // The first Home Screen frame, once the closing animation is quiet for a moment.
        await BrainTrace.time("homeframe") {
            _ = await screen.fresh(since: since, timeout: 1.5)
            await screen.settled(quiet: 0.15, least: 0.05, most: 0.8)
        }
        try check()
        guard inBackground, var before = screen.frame else { return false }
        var spot = CGPoint(x: 0.5, y: 0.5)
        let shown = try await read(screen, open, phase: "ocr") ?? []
        if let label = label(for: open.target, in: shown) {
            spot = iconPoint(label: label.box)
            try check()
            try await BrainTrace.time("tap", open.target.name) { try await pointer.tap(spot.x, spot.y, aim: false) }
        } else {
            guard try await search(open, shown, pointer: pointer, screen: screen, check: check) else { return false }
            // Opened is judged against the search results, not the Home Screen: the open search sheet is no launch.
            before = screen.frame ?? before
            try check()
            try await pointer.key("enter")
        }
        let tapped = brainNow()
        // Opened: any frame after the tap that differs from the Home Screen (the launch animation counts).
        let deadline = tapped + 1.5
        while brainNow() < deadline {
            try check()
            if await screen.fresh(since: tapped, timeout: 0.3) != nil,
               FrameVision.changed(before, screen.frame, ignore: [spot]) { return inBackground }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Home Screen search: the Search pill (or a pull down from the middle), type the name; true once the top hit shows.
    @MainActor private static func search(_ open: Opening, _ shown: [ScreenElement], pointer: Gestures, screen: BrainScreen,
                                          check: () throws -> Void) async throws -> Bool {
        let started = brainNow()
        defer { BrainTrace.mark("search", brainNow() - started, open.target.name) }
        if let pill = searchPill(shown) {
            try await pointer.tap(pill.center.x, pill.center.y, aim: false)
        } else {
            try await pointer.swipe(0.5, 0.3, 0.5, 0.6, hold: false)
        }
        let opened = brainNow()
        _ = await screen.fresh(since: opened, timeout: 0.8)
        await screen.settled(quiet: 0.2, least: 0.1, most: 1)
        try check()
        // Apple's apps go by their localized name, so an Arabic phone gets the Arabic name the goal used.
        let arabicPhone = Locale.preferredLanguages.first?.hasPrefix("ar") == true
        try await pointer.type(open.arabic && arabicPhone ? open.spoken : open.target.name)
        let typed = brainNow()
        // The typed query matches too; a second match is the result list, then Return opens the top hit.
        while brainNow() - typed < 2 {
            try check()
            _ = await screen.fresh(since: brainNow(), timeout: 0.3)
            if let els = try await read(screen, open, phase: "ocr-results"), matches(open.target, els).count >= 2 {
                return true  // the caller presses Return on the top hit
            }
        }
        return false
    }

    /// OCR of the full-resolution frame: fast, then accurate (Arabic, small labels) when the fast pass misses.
    @MainActor private static func read(_ screen: BrainScreen, _ open: Opening, phase: String) async throws -> [ScreenElement]? {
        guard let jpeg = screen.fullJPEG else { return nil }
        if !open.arabic {
            let els = try await BrainTrace.time(phase, "fast") { try await ScreenReader.elements(jpeg: jpeg, fast: true) }
            if label(for: open.target, in: els) != nil { return els }
        }
        return try await BrainTrace.time(phase, "accurate") { try await ScreenReader.elements(jpeg: jpeg, fast: false) }
    }
}
#endif
