# Device tests

`scripts/device-run.sh` starts a task on the iPhone through a `phoneagent://run` link, waits for it to finish and
prints the outcome with per-phase timings from `Documents/fast-agent-trace.log`. Phone Agent must already share
the full screen with the mouse calibrated. Tell it which phone and which build to use:

```sh
export PHONE_AGENT_DEVICE=<udid from: xcrun devicectl list devices>
export PHONE_AGENT_BUNDLE=<the PA_BUNDLE_ID in Config/Local.xcconfig>
scripts/device-run.sh "<task>" [--repeat N] [--timeout S] [--device UDID] [--bundle ID]
```

The `brief` phase is the task brief (`PhoneAgent/Brain/BrainBrief.swift`). Its note says whether it was ready
before the first look or held it (and for how long), or why there was none (timed out, call failed, unreadable).

## Leaving and opening apps

| Task | Expected |
|---|---|
| `scripts/device-run.sh "Open WhatsApp"` | Phone Agent leaves with the home flick, WhatsApp opens from its Home Screen label, and the run ends without a model call. |
| `scripts/device-run.sh "Open Settings and go to Wi-Fi"` | Settings opens without a model call; the actor taps Wi-Fi and the run ends on the Wi-Fi page. |

If an app's icon is not on the Home Screen page in front, the fast path types its name into Home Screen search instead.

## Research and messaging

| Task | Expected |
|---|---|
| `scripts/device-run.sh "Open Safari and search the best coffee in Riyadh"` | Safari opens without a model call; the address bar gets a real query (e.g. "best coffee shops in Riyadh"), Enter, and the run ends with the top places in one or two sentences. |
| `scripts/device-run.sh "What's the weather in Riyadh tomorrow?"` | The brief picks Safari and a weather query; the run ends with the forecast as the answer (a call speaks it back as is). |
| `scripts/device-run.sh "Open WhatsApp and send مرحبا to Abdullah"` | WhatsApp opens, the chat with Abdullah is found, مرحبا is typed, and the run stops before Send: "say send to send it". |

Follow-ups need the session context, so run them right after the request they refer to (within 2 minutes, or in a call):

| Task | Expected |
|---|---|
| `"type hi to him in Arabic"` after opening a chat | مرحبا is typed in the open chat; nothing is searched. |
| `"send it"` after the above | Send is tapped and the message shows in the chat. |
| `"open Safari and search that thing"` after asking about something | The query names that thing, not the words "that thing". |

Check the step log's "Brief" line for the intent, query and text the actor got.
