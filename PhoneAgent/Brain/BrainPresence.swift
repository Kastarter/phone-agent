// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan
import Foundation
import UIKit

// The agent works on the phone this app runs on, so the app must be out of the way: a run starts by sending it
// to the Home Screen (and checks that iOS really put it in the background), and holds while it is in front.

@MainActor private var appInBackground: Bool { UIApplication.shared.applicationState == .background }

@MainActor private func waitForBackground(_ seconds: Double) async -> Bool {
    let deadline = brainNow() + seconds
    while !appInBackground {
        if brainNow() > deadline || Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return true
}

/// Leaves Phone Agent without the model: the accessory's Home key or the home flick, retried once. Never Cmd+H:
/// iOS ignores it from the stick.
@MainActor func leaveApp(_ pointer: BrainPointer) async -> Bool {
    // The flick (twice), then the Home key; on the device iOS ignored the key, so it never goes first.
    for useKey in [false, false, true] {
        if appInBackground { return true }
        do { if useKey { try await pointer.homeKey() } else { try await pointer.goHome() } } catch { continue }
        if await waitForBackground(useKey ? 1 : 1.5) { return true }
    }
    return appInBackground
}

/// Before each look and gesture of a run. If the agent itself brought the app to the front (it acted under 3 s
/// ago), or the run was just resumed here, send the app away at once; if the user opened it, wait until they
/// leave. `onHold` shows the paused hint.
@MainActor func holdWhileInFront(pointer: BrainPointer, lastActed: Double, running: Bool, capture: BrainScreen,
                                 resumedAt: Double, onHold: () -> Void) async throws {
    guard UIApplication.shared.applicationState == .active, running else { return }
    let ours = brainNow() - lastActed < 3 || brainNow() - resumedAt < 5
    let since = brainNow()
    var away = false
    if ours { away = await leaveApp(pointer) }
    if !away {
        onHold()
        while !appInBackground {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }
    _ = await capture.fresh(since: since, timeout: 3)  // a frame of the screen that is in front now
    await capture.settled()
}
