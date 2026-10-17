# Third-Party Notices

## esp32-iphone-agent

The fast agent in `PhoneAgent/Brain/` is adapted from
[esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan, under the MIT License.
Each adapted file starts with the line `// Adapted from esp32-iphone-agent (MIT), Copyright (c) 2026 Henry Yuan`.

| File in this repository | Adapted from |
|---|---|
| `PhoneAgent/Brain/JSON.swift` | `ios/IPhoneAgent/Agent/JSON.swift` |
| `PhoneAgent/Brain/BrainActions.swift` | `ios/IPhoneAgent/Agent/Actions.swift` |
| `PhoneAgent/Brain/FrameVision.swift` | `ios/IPhoneAgent/Agent/Vision.swift` |
| `PhoneAgent/Brain/ProbeFit.swift` | `ios/IPhoneAgent/Agent/ProbeFit.swift` |
| `PhoneAgent/Brain/BrainPrompts.swift` | `prompts/actor.md`, `prompts/planner.md`, `prompts/app-rules.md`, `ios/IPhoneAgent/Agent/Prompts.swift` |
| `PhoneAgent/Brain/AssistiveTouchSpots.swift` | `ios/IPhoneAgent/Agent/AssistiveTouchSpots.swift` |
| `PhoneAgent/Brain/BrainLLM.swift` | `ios/IPhoneAgent/Services/LLMClient.swift` |
| `PhoneAgent/Brain/BrainPointer.swift` | `ios/IPhoneAgent/Agent/Pointer.swift` |
| `PhoneAgent/Brain/FastAgent.swift` | `ios/IPhoneAgent/Agent/AgentLoop.swift` |
| `PhoneAgent/Brain/BrainPresence.swift` | `ios/IPhoneAgent/App/AppPresence.swift` |
| `PhoneAgent/Brain/BrainScreen.swift` | `ios/IPhoneAgent/Video/VideoFeed.swift` (`ScreenSource`) |
| `PhoneAgent/Brain/BrainDevice.swift` | `ios/IPhoneAgent/Board/BoardCommands.swift` (`HIDDevice`) |
| `PhoneAgent/Brain/BrainPorts.swift` | `ios/IPhoneAgent/Services/LLMClient.swift`, `ios/IPhoneAgent/Agent/Pointer.swift`, `ios/IPhoneAgent/Video/VideoFeed.swift`, `ios/IPhoneAgent/Board/BoardCommands.swift` (protocols) |
| `PhoneAgent/Brain/BrainCommand.swift` | `docs/ble-protocol.md`, `hardware/hid_bridge/hid_bridge.ino` (command set) |
| `PhoneAgent/Views/CalibrationView.swift` (probe procedure) | `ios/IPhoneAgent/App/TouchCalibration.swift` |

```
MIT License

Copyright (c) 2026 Henry Yuan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
