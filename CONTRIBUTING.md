# Contributing

Thanks for taking a look. SolidFerry is built and tested by one person with a handful of devices,
so the most valuable contribution is often the simplest: **run it with your phone and tell us what
happened.** Every Android maker bends MTP and ADB a little differently, and a report from a device
we've never seen is worth more than a feature.

Anyone can generate an app like this with AI these days. What's hard is the long tail — the phone
that hangs when you cancel a read, the folder that takes 18 seconds to list, the file that comes
back 4 GB − 1 bytes long. Those get fixed one device at a time, and we'd rather polish one tool
together than see ten half-finished ones.

## Ways to help

- **Device reports**: open a [device report](../../issues/new?template=device_report.yml) with your
  model and Android version, even if everything worked. The tested-devices table in
  [docs/DEVICE_TESTS.md](docs/DEVICE_TESTS.md) grows from these.
- **Run the device tests** on your phone (below) and paste the output into the report.
- **Bugs**: a [bug report](../../issues/new?template=bug_report.yml) with the steps, the connection
  (USB debugging / File transfer / Wi-Fi) and what you saw.
- **Code**: small, focused pull requests. For anything larger, open an issue first.
- **Translations**: strings live in `App/Localizable.xcstrings` (English and Korean today).

## Development setup

Requirements: Xcode 26+ (on macOS 15.6 or later; the app itself runs on macOS 14+),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftFormat](https://github.com/nicklockwood/SwiftFormat),
and Android platform-tools (`adb`) for the ADB path.

```sh
brew install xcodegen swiftformat
make run      # generate the Xcode project, build, open the app
make test     # unit tests (SolidFerryKit)
make cli      # the developer CLI: Packages/SolidFerryKit/.build/release/sferry
make lint     # what CI runs (SwiftFormat, whitespace rules only)
```

The Xcode project is generated from `project.yml` — don't edit `SolidFerry.xcodeproj`; change
`project.yml` and run `make proj`.

Layout:

```
App/                          the SwiftUI app
Packages/SolidFerryKit/
  Sources/DeviceCore/         DeviceFileSystem protocol and transport-independent models
  Sources/AdbKit/             adb server client (host services, sync protocol, shell)
  Sources/UsbKit/             USB device discovery (IOKit)
  Sources/MtpKit/             MTP over IOUSBHost (PTP codec, session, file system)
  Sources/TransferKit/        planning, conflict policies, zip, device-to-device copy
  Sources/sferry/             developer CLI: device tests, benchmarks, experiments
  Tests/                      unit tests (Swift Testing)
docs/                         PRD, device quirks, device tests
scripts/                      end-to-end tests through the app, DMG packaging
```

## Device tests

Unit tests can't tell you how a real phone behaves, so changes to device behavior are checked on
devices:

```sh
sferry devices                              # serials of connected devices
sferry -s SERIAL devtest adb quick          # phone with USB debugging on
sferry -s SERIAL devtest mtp quick          # phone in File transfer mode (quit the app first)
```

The tests only create and delete their own `/sdcard/Download/xfer-devtest-*` folder, with
generated files; nothing else on the phone is read or changed. See
[docs/DEVICE_TESTS.md](docs/DEVICE_TESTS.md) for the two-device and queue tests.

## Before opening a pull request

1. `make lint` and `make test` pass.
2. If it changes how the app talks to a device: the device tests pass on at least one phone
   (say which in the PR).
3. New user-facing strings are in `App/Localizable.xcstrings` (English, plus Korean if you can —
   otherwise we'll add it).

[AGENTS.md](AGENTS.md) has the project's conventions in one page (layers, quirk IDs, wording).
It's written for AI coding agents, and it's just as useful for people.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
