# AGENTS.md

SolidFerry is a native macOS app (SwiftUI + a Swift package) for browsing and transferring files
between Android devices and a Mac, over ADB and MTP. What it is for: [docs/PRD.md](docs/PRD.md).
Device and protocol behavior it works around: [docs/QUIRKS.md](docs/QUIRKS.md). Device tests:
[docs/DEVICE_TESTS.md](docs/DEVICE_TESTS.md).

## Build & test

```sh
make build    # xcodegen generate + Debug build (build/DerivedData.noindex/Build/Products/Debug/SolidFerry.app)
make run      # build and open
make test     # SolidFerryKit unit tests (Swift Testing)
make cli      # the developer CLI, sferry
make format   # SwiftFormat (CI runs `swiftformat --lint .`)
```

The Xcode project is generated from `project.yml` and is not checked in.

## Rules

- **User-facing text** says what happened and what to do next. It never describes internals
  (request counts, parallelism, retries).
- **Localization**: write strings in English in code and add the Korean translation to
  `App/Localizable.xcstrings`. Outside SwiftUI literals use `String(localized:)`. A ternary of
  literals (`Text(cond ? "A" : "B")`) becomes a `String` and is not translated — write
  `cond ? Text("A") : Text("B")`. The package has no user-facing text, only typed errors; the
  app's `UserMessage` turns them into sentences.
- **Quirks**: known issues of devices and existing implementations (libmtp, AOSP adb, …) are
  recorded as data in `docs/QUIRKS.md`, and checked at connect time where possible. Anything that
  can hang a device is worked around defensively. Every entry has an ID (A·S·M·G·H); code that
  works around one points at it in a comment, e.g. `QUIRKS M9`.
- **Device tests**: a change to device behavior is checked with
  `sferry -s SERIAL devtest adb|mtp quick` (two devices: `sferry devtest-pair A:adb B:mtp quick`;
  the transfer queue and conflict policies: `scripts/queue-test.sh A B`). They only touch their
  own `/sdcard/Download/xfer-*` folder. When a test fails, fix the implementation, not the test.
- **Layers**: the UI sees only `DeviceFileSystem` and its `capabilities`. ADB/MTP differences live
  in the backends.
- **Names**: the app name lives only in `project.yml` (display name, bundle ID) and in
  project/package/CLI names. Temporary names and test folders made on a device or the Mac come
  from `WorkNames` (tag `xfer`); app identity (logs, storage folder, pasteboard type) from the
  bundle ID (`WorkNames.subsystem`); development launch arguments are `-dev.name` (listed at the
  top of `App/DevelopmentLaunchArguments.swift`).
- **Docs and comments** describe the app as it is, in the present tense: no history, no dates of
  findings or decisions, no device serial numbers. Tested devices are named by model.
- **Commits** carry no AI attribution: no `Co-Authored-By` trailers for AI tools and no
  "Generated with …" lines. Attribution is limited to human contributors.
- **Translated docs** stay in step: a change to `README.md` or `docs/PRD.md` goes into
  `README.ko.md` / `docs/PRD.ko.md` in the same commit.
