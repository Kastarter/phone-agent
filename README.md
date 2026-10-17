# Phone Agent

An AI agent that uses a real iPhone the way you do: it looks at the screen and moves a pointer. A small Bluetooth stick does the tapping.

No jailbreak, no Mac at run time, no cable. The phone, an ESP32-S3 stick and an app.

> [!NOTE]
> This is an experiment, shared so others can build on it. It works end to end on an iPhone running iOS 27 with an M5StickS3, and it is still rough. Watch it while it runs and keep the stop button close.

## The experiment

iOS doesn't let one app tap buttons in another. It does let you pair a Bluetooth mouse, and with AssistiveTouch turned on, a click is a tap and a drag is a swipe. So if a small board acts as a Bluetooth mouse and keyboard, an app on the phone can watch the screen, decide what to do and tell the board where to click.

The question: can that loop be quick enough that you can just ask your phone to do something, or call it and talk? So far the answer is yes, as long as the model is asked as rarely as possible and the phone does everything it can by itself.

## How it works

```
                 ┌─────────────────────────── iPhone ───────────────────────────┐
  task or call ▶ │  Phone Agent app                                             │
                 │   ├─ Screen: full-screen sharing, frames in memory           │
                 │   ├─ Fast agent: brief, actor (up to 6 actions per look)     │
                 │   ├─ Fast paths: Home Screen labels and search, on device    │
                 │   └─ Pointer and keyboard over BLE ─┐                        │
                 └─────────────────────────────────────┼────────────────────────┘
                                                       ▼
                             ESP32-S3 stick: Bluetooth HID mouse and keyboard
                                                       │
                             AssistiveTouch pointer ◀──┘  (click = tap, drag = swipe)
```

The Fast agent in `PhoneAgent/Brain/` runs every task:

- **Leaving the app.** A task starts inside Phone Agent, so the agent first goes home with a flick from the bottom edge. The pointer is pinned on the edge first, so the flick always starts on the home bar. The stick's Home key is only a last resort.
- **Opening apps instantly.** When the task names an app, the phone reads the Home Screen labels with on-device text recognition and taps the icon, or types the name into Home Screen search. No model call is needed, and a plain "open WhatsApp" finishes without one.
- **Task brief.** While the app leaves, one text-only call turns the request into what the actor needs: the intent, the app, the exact text to type in its final script ("hi in Arabic" becomes "مرحبا"), a real search query, whether you want an answer back, and what needs your OK before it happens.
- **Actor loop.** Each look sends one screenshot and gets back up to six actions. A planner writes a plan only when the actor is stuck.
- **Typing.** Text is typed as keystrokes through the layouts the app learned in Keyboard Check, and the device switches input sources for other scripts by itself.
- **Aim correction.** The pointer is relative. The app tracks it in mouse units, re-homes it to the nearest corner now and then, and learns a per-axis correction from where its taps really land, so taps get better as it works.

**Voice calls.** The app can join a [LiveKit](https://livekit.io) room with any LiveKit voice agent that supports client tools. The agent calls `control_phone` with your words, the Fast agent does the work, and the agent tells you the result. A call also keeps the app running while the agent works in other apps.

Model calls go to any OpenAI-compatible Chat Completions endpoint. The default is GPT-6 Luna on OpenRouter. The chat, notes and web search features can also use AWS Bedrock.

## What we measured on the device

- iOS ignores Cmd+H, Cmd+Space and the consumer AC Home key from a Bluetooth keyboard, so leaving an app and opening Spotlight have to be done with the pointer.
- An app in the background can't use the pasteboard, so text can't be pasted into another app. Everything is typed key by key.
- Apple's Arabic hardware keyboard layout is not the PC Arabic layout. Keyboard Check learns what each key really types, instead of assuming a layout.

## Hardware

| Part | Notes |
|---|---|
| ESP32-S3 board | Tested on an [M5StickS3](https://docs.m5stack.com/en/core/StickS3) (ESP32-S3-PICO-1, 8 MB flash, battery, so it runs untethered). Any ESP32-S3 with BLE should work. |
| iPhone | iOS 27. |
| Mac | Only to flash the board and build the app: Xcode 27 and ESP-IDF 5.5.4. |

> [!IMPORTANT]
> On the M5StickS3, GPIO48 is the shared I2C clock line for the power chip, IMU and audio codec. Keep the firmware's optional WS2812 status LED disabled (it is by default in `firmware/sdkconfig.defaults`), or it drives signals into that bus.

After flashing firmware that changes the HID report map, forget `AgentMouse-S3` on the iPhone and pair again. iOS caches the old map with the pairing.

## Quick start

1. **Clone.** `git clone https://github.com/Kastarter/phone-agent.git`
2. **Configure signing.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team ID and a bundle ID of your own.
3. **Add keys** (optional). Put the git-ignored key files from the table below in `PhoneAgent/Resources/`, or enter a key in Settings later.
4. **Flash the stick.** See [docs/firmware.md](docs/firmware.md).
5. **Build and run** the `PhoneAgent` scheme on your iPhone. Turn on Developer Mode when asked.
6. **Pair.** Settings → Accessibility → Touch → AssistiveTouch → On → Devices → Bluetooth Devices → `AgentMouse-S3`. Turn off Snap to Item.
7. **Calibrate.** In the app: Devices & Calibration → Connect AgentMouse → Start Calibration, with the phone upright. It takes about 8 clicks.
8. **Keyboard Check.** Run it right after calibration, once for each keyboard you type in.
9. **Share the screen.** Start screen sharing in the app, choose the entire screen, and give it a task.

The full walkthrough is in [docs/setup.md](docs/setup.md), and the design is in [docs/architecture.md](docs/architecture.md).

## Keys and config

Keys never go into git. The app reads them from the Keychain (entered in Settings) or from these git-ignored files, bundled at build time:

| File (git-ignored) | Used for |
|---|---|
| `Config/Local.xcconfig` | Your `DEVELOPMENT_TEAM` and `PA_BUNDLE_ID` (see `Config/Local.xcconfig.example`) |
| `PhoneAgent/Resources/OpenRouterKey.txt` | An OpenRouter key for the default model |
| `PhoneAgent/Resources/BedrockCredentials.json` | AWS Bedrock credentials for chat (`{"AccessKeyId": "…", "SecretAccessKey": "…"}`) |
| `PhoneAgent/Resources/VoiceAgent.json` | The voice agent for calls (see `VoiceAgent.example.json` and [docs/setup.md](docs/setup.md)). Without it, the call button is hidden. |

`scripts/bedrock-credentials.sh <env-file>` mints 12-hour STS credentials and copies them to the clipboard, so you can paste them on the phone instead of bundling a long-term key.

## Project layout

```
PhoneAgent/          iOS app (SwiftUI)
  Brain/             the Fast agent: brief, actor and planner prompts, pointer, fast paths, screen reading
  Services/          task engine, BLE transport, capture, calls, chat and other app features
  Views/             UI
Shared/              models shared with the Live Activity extension
Activity/            Live Activity and Dynamic Island
Config/              shared build settings; your Local.xcconfig goes here
firmware/            ESP32-S3 BLE HID mouse and keyboard (ESP-IDF, NimBLE)
Tests/               offline checks (no phone, Bluetooth or network)
scripts/             checks, firmware build, device runs, Bedrock credentials
```

Run the offline checks with `bash scripts/check.sh path/to/PhoneAgent.app`.

## Limitations

- **What it can't see.** iOS hides passcode entry, Apple Pay and DRM video from screen capture, so the agent can't see or act on them.
- **Icon-only screens.** The actor works from screenshots of about 480 px, so tiny icons and dense screens can be missed.
- **Calibration.** Recalibrate after changing pointer speed, tracking settings or the board.
- **Portrait only**, for now.
- **Speed.** Each look is one model call. A short task takes a few seconds; a long one can take a minute.

## Responsible use

Only automate devices and accounts you own or may use, and respect the terms of the apps you drive. The agent acts with your hands. Keep it supervised, especially around messages, payments and anything you can't undo. It stops before sending a message and asks you first.

## Contributing

Contributions are welcome: better aim on small targets, more keyboards, other boards, faster loops. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. Bug reports with a short screen recording help the most.

## Special thanks

- [boboabw/phone-agent](https://github.com/boboabw/phone-agent): the iOS app and its UI started from it (used and released here with the author's permission), and it showed the whole thing works over Bluetooth with no cable.
- [onehumanbeing/esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan: the Fast agent brain in `PhoneAgent/Brain/` is adapted from it under the MIT License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Thank you both for sharing your work in the open.

## License

[MIT](LICENSE)
