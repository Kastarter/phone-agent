# Offline product-state checks

Run on a Mac with Xcode:

```sh
bash Tests/ProductState/run.sh
```

The script compiles the production `AgentEngine` and `FastAgent` with the Fast agent's brief, prompts, parsing and fast paths, plus `TaskHistoryStore`, `PrivacyConsent` and the shared models. Only the engine's UIKit import is swapped for CoreGraphics. `Environment.swift` supplies offline fakes for the screen, capture, pointer, board and model, so a run's model replies and gestures are scripted. Temporary data goes in a temp directory and a separate preferences domain. It never connects to a phone, Bluetooth or a model, never installs the app, and spends no model credits.

The checks cover consent and recipient changes, Bedrock endpoints refused for phone tasks, old-settings decoding, history save/rename/delete/limits/corruption recovery, no resumed execution after relaunch, pause and cancel, no continuing during release, a new look on resume, manual takeover, stale replies after stop, voice command matching, additions reaching the next actor prompt, and the call session context and prompt assembly.

They don't check ActivityKit, camera, voice, memory indexing, file generation, PhoneAgentViewModel, SwiftUI sheets, the Keychain, a real model, real screen changes, BLE/HID, background execution or on-device UI. The full hardware path still needs testing on a device.
