# Contributing

Thanks for helping. This is an experiment, so small, focused pull requests are easiest to review and merge.

## Before you start

- Open an issue for anything larger than a bug fix, so we can agree on the approach first.
- Keep changes in the style of the surrounding code: compact Swift, few comments, no new dependencies unless they earn their place.
- Never commit keys or personal settings. API keys, AWS credentials and the voice agent config belong in the Keychain or in the git-ignored files listed in the README; your team ID and bundle ID go in `Config/Local.xcconfig`.

## Checks

Run the offline checks before you open a pull request. They need Xcode but no phone, Bluetooth or network:

```sh
xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent -destination 'generic/platform=iOS' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
bash scripts/check.sh build/dd/Build/Products/Debug-iphoneos/PhoneAgent.app
```

For firmware changes, build with `bash scripts/build-firmware.sh` (ESP-IDF 5.5.4) and say which board you tested on.

## Good first areas

- Better aim on small and icon-only targets (`PhoneAgent/Brain/BrainPointer.swift`).
- More apps and aliases for the Home Screen fast path (`PhoneAgent/Brain/AppLauncher.swift`), each one verified on a device.
- More keyboards in Keyboard Check (`PhoneAgent/Services/KeyboardLayouts.swift`).
- Support for other ESP32-S3 boards.

Files in `PhoneAgent/Brain/` that start with the esp32-iphone-agent notice are adapted MIT code. Keep that first line when you change them, and add new adapted files to `THIRD_PARTY_NOTICES.md`.

## Reporting bugs

Include the iPhone model and iOS version, the board, the model you used, the task you gave it, the step log, and a short screen recording if you can. Blur anything private.

By contributing, you agree that your contributions are licensed under the MIT License.
