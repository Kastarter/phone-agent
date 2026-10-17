# Setup

## 1. Signing and keys

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set:
   - `DEVELOPMENT_TEAM`: your Apple Developer team ID.
   - `PA_BUNDLE_ID`: a bundle ID you own. The Live Activity extension uses `$(PA_BUNDLE_ID).activity`.

   Without it, the project builds with the placeholder `dev.example.phoneagent` and no team, which can't be installed on a phone.
2. Optional key files in `PhoneAgent/Resources/` (all git-ignored, bundled at build time):
   - `OpenRouterKey.txt`: an OpenRouter key. With it, the app starts on GPT-6 Luna through OpenRouter.
   - `BedrockCredentials.json`: AWS credentials for chat, notes and search answers on Bedrock.
   - `VoiceAgent.json`: the voice agent for calls (see [Voice calls](#voice-calls)).

   You can also enter a model key in Settings, where it is stored in the Keychain.

## 2. Build and install the app

Open `PhoneAgent.xcodeproj` in Xcode 27, select the `PhoneAgent` scheme, connect your iPhone, unlock it and run. The first time, iOS asks you to turn on Developer Mode (Settings → Privacy & Security → Developer Mode), which restarts the phone.

From the command line:

```sh
xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent -configuration Debug \
  -destination 'id=<your-device-udid>' -derivedDataPath build/dd -allowProvisioningUpdates build
xcrun devicectl device install app --device <your-device-udid> build/dd/Build/Products/Debug-iphoneos/PhoneAgent.app
```

## 3. Flash and pair the stick

Flash the firmware ([firmware.md](firmware.md)). Then on the iPhone, go to Settings → Accessibility → Touch → AssistiveTouch, turn it on, open Devices → Bluetooth Devices and pick `AgentMouse-S3`. A pointer appears on screen. Turn Snap to Item off.

After a firmware update that changes the HID report map, forget `AgentMouse-S3` on the iPhone and pair again.

## 4. Calibrate and check the keyboard

In the app, open the sidebar → Devices & Calibration → Connect AgentMouse. Wait until both the mouse and the control channel show as ready. Then start calibration with the phone upright and don't touch the screen: it takes about 8 clicks. Recalibrate after changing pointer speed or tracking settings.

Keyboard Check follows calibration. The stick types every key into a hidden field, so the app learns what your keyboard really inserts. English is built in. Add each other keyboard you type in (for example Arabic) in iOS Settings first, then run the check again and switch to it when asked.

## 5. Choose a model

Settings (gear at the bottom of the sidebar) → Model Connection. Phone tasks need a vision-capable model on an OpenAI-compatible Chat Completions endpoint: OpenRouter (GPT-6 Luna by default), OpenAI, or a custom endpoint. AWS Bedrock works for chat, notes and search answers: pick a model and paste temporary credentials from `bash scripts/bedrock-credentials.sh <env-file>`.

The first run asks you to confirm which provider receives your screen and task data.

## 6. Run a task

Start screen sharing in the app and choose the entire screen. Type a task such as `Open Settings and go to Wi-Fi` and press start. Phone Agent leaves to the Home Screen by itself and works from there. You can pause, stop or take over at any time, from the app, the Dynamic Island, or by voice.

Protected screens (passcode, Apple Pay, DRM video) show up blank to the agent.

## Voice calls

Calls work with any [LiveKit](https://livekit.io) voice agent that supports client tool calls. Copy `PhoneAgent/Resources/VoiceAgent.example.json` to `PhoneAgent/Resources/VoiceAgent.json` (git-ignored) and fill it in:

```json
{
  "tokenURL": "https://voice.example.com/api/tokens/client",
  "agentName": "your-agent-name",
  "apiKey": "YOUR_API_KEY",
  "apiSecret": "YOUR_API_SECRET",
  "roomMetadata": { "intro_message": "I'm on the line. What should I do on your phone?" }
}
```

The call button shows only when the file is bundled and `tokenURL` (HTTPS), `agentName`, `apiKey` and `apiSecret` are all set. `roomMetadata` is optional: its fields are passed to your agent as they are.

**Token request.** To start a call, the app sends:

```
POST <tokenURL>
Authorization: Bearer <apiKey>:<apiSecret>
Content-Type: application/json

{"identity": "phone-…", "roomName": "call-…", "agentName": "<agentName>",
 "roomMetadata": {…your roomMetadata…, "client_tools": {"participant_identity": "phone-…", "tools": [ … ]}}}
```

and expects `{"token": "<LiveKit access token for that room and identity>", "url": "<LiveKit server URL>"}`. Getting the named agent into the room with that metadata (for example through LiveKit agent dispatch) is up to your service.

**Client tools.** The agent calls the phone over LiveKit RPC: method `client_tool_call` to the participant in `client_tools.participant_identity`, payload `{"tool": "<name>", "arguments": {…}}`. The phone answers `{"response": "<what happened>"}`, or `{"ok": false, "error": "…"}`. The tools, described in full in `client_tools.tools`:

| Tool | Arguments | What it does |
|---|---|---|
| `control_phone` | `instruction`: the user's words, verbatim | Runs a phone task and returns when it ends (or after about 110 s with "still working"). A new call replaces the task in flight. |
| `stop_phone_task` | none | Stops whatever the phone is doing. |

The app also shows live captions from the `lk.transcription` text stream.
