# Architecture

The app runs one loop: look at the screen, decide a few actions, do them through the Bluetooth stick, look again. Everything except the model calls runs on the phone.

```
ScreenCaptureKit frame ─▶ BrainScreen (≈480 px JPEG, settle detection)
                                   │
 ┌──────────────┐   ┌──────────────▼─────────────┐   ┌──────────────┐
 │ AgentEngine  │──▶│ FastAgent                  │──▶│ BrainPointer │──▶ BrainDevice ─▶ BLETransport ─▶ stick
 │ task, phases │   │  brief, actor, planner     │   │ aim, rehome  │
 │ approvals    │   │  (BrainLLM: any OpenAI-    │   └──────────────┘
 └──────────────┘   │   compatible endpoint)     │
                    └────────────────────────────┘
```

`PhoneAgent/Brain/` is adapted from [esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent) (MIT, Henry Yuan; see `THIRD_PARTY_NOTICES.md`). `BrainPorts.swift` holds the small protocols between the parts (model, gestures, board, screen), so the offline checks can run the real engine and agent against fakes.

## The task engine

`PhoneAgent/Services/AgentEngine.swift` owns a task: its record and step log, the phases the UI and Live Activity show, approvals when "Confirm each step" is on, pause, take over, add instructions, resume, stop, the step limit, and releasing the stick's input when a run ends. A run:

1. leaves Phone Agent (see below) while the task brief is fetched,
2. opens the task's app without a model when it can,
3. asks the actor for the next actions, up to six per look,
4. performs them, checking after a tap that is followed by typing that the tap really changed the screen,
5. records whether the screen changed, and looks again until the actor says `done` or `fail`.

The actor repeating a move that changed nothing three times, or replying `replan`, brings in the planner. Three hiccups in a row hand the task to you.

## Leaving the app

A task starts inside Phone Agent, so the agent has to get out of the way first (`BrainPresence.swift`). It flicks up from the home bar: the pointer is pushed past the bottom edge at mid-width, so its height is exact, and then it drags up. If iOS has not put the app in the background, it flicks again, and only then tries the stick's AC Home key, which iOS ignored on the device. While a run is going, the app holds whenever Phone Agent comes back to the front. If the agent brought it there itself, it leaves again at once.

## Opening apps

`BrainFastPaths.swift` reads the Home Screen with Apple Vision text recognition (`ScreenReader.swift`), finds the label of the app the task names (`AppLauncher.swift` lists the names and English and Arabic aliases), and taps just above it. When the label is not on the current page, it opens Home Screen search, types the name and presses Return on the top hit. A goal that is only "open X" ends there without any model call. Otherwise the actor carries on from the opened app.

## Task brief

At the start of a run, while Phone Agent leaves, `BrainBrief` makes one text-only call to the same model with the request, the session context and the date. It returns JSON: the intent, the app, 2 to 6 steps, the exact text to type in its final script ("hi in Arabic" becomes "مرحبا"), a real search query for research ("search that thing" resolved from the context), whether the user wants an answer back, the done condition, what needs the user's OK, and a clarifying question only when the request is ambiguous even with the context. The actor prompt carries it as a "Brief" block. A question stops the run and a call speaks it. An answer deliverable ends with the information in `done`, spoken back as is. Brief steps that send, pay, delete or call are dropped, so a brief can only add caution. The first look waits for the brief at most 4 s from the start, and the run goes on without one on failure.

## Actor and planner

`FastAgent.swift` builds the actor prompt from the session context (earlier requests and how they ended), the goal, the brief or plan, and the last actions with whether each changed the screen. The actor answers with a `THINK:` line and up to six `DO:` lines (`tap`, `swipe`, `path`, `circle`, `type`, `key`, `home`, `back`, `wait`, `done`, `fail`, `replan`), with coordinates on a 0 to 1000 grid. The first actor call starts on the first frame after leaving the app, while the screen is still settling, and is only used if the settled screen still looks the same.

## Pointer and aim

The pointer is relative. `BrainPointer` tracks it in mouse units from the touch-probe calibration, re-homes it into the corner nearest the next target every 20 gestures or after a big miss, and learns a per-axis line from where its taps really land. Before a precise tap it wiggles the pointer, finds it in the frame and corrects the aim. Calibration (`CalibrationView.swift`) fits one line per axis from about 8 probe clicks.

## Typing

`BrainDevice` maps the Fast agent's board commands onto the app's encrypted BLE protocol. Text is typed as keystrokes. Keyboard Check (`KeyboardCheckView.swift`) has the stick type every US key, plain and with Shift, into a hidden field, and stores what each input source inserts (`KeyboardLayouts.swift`). Typing then plans the keys for each script from those maps, switches the input source with the on-screen globe key when needed, and reads the field back to check the result. Pasting is not an option: an app in the background can't use the pasteboard.

## Voice calls

`CallController.swift` joins a LiveKit room with a voice agent configured in `PhoneAgent/Resources/VoiceAgent.json`. Speech recognition, the language model and text-to-speech run in the agent. The app registers the RPC method `client_tool_call` and lists two client tools in the room metadata: `control_phone` (one `instruction` string) and `stop_phone_task`. Each `control_phone` call replaces the task in flight and returns `{"response": "..."}` with what happened, which the agent speaks. A call also keeps the app alive in the background while it works in other apps, and gives follow-ups ("send it", "him") the context of the call. The token contract is in [setup.md](setup.md#voice-calls).

## Other features

The chat, camera questions, meeting notes and web search answers use `VisionClient.swift` with the same model settings. `BedrockClient.swift` adds AWS Bedrock for those: when the endpoint host is `bedrock-runtime.<region>.amazonaws.com`, the Chat Completions request is rewritten as a SigV4-signed Converse call and the reply is mapped back. Phone tasks need an OpenAI-compatible endpoint.

## Hands: the stick

The firmware (`firmware/main/main.c`, ESP-IDF and NimBLE) is a composite BLE HID device, mouse plus keyboard plus consumer control, with an encrypted control service. The app sends sequenced commands. The board plays pointer moves at a fixed rate and reports when each one finishes, so clicks land after the pointer arrives. See [firmware.md](firmware.md).

## Privacy

Screenshots and the task go to the model endpoint you chose, and the app asks for consent per recipient. Keys live in the Keychain or in git-ignored files bundled at build time. Protected screens (passcode, Apple Pay, DRM) are never captured by iOS.
