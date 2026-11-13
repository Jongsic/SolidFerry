# Security Policy

## What the app does

SolidFerry is a local desktop app. It has no accounts, no cloud service and no telemetry.

- **Devices**: it talks to Android devices over USB (MTP, directly through IOKit) and through the
  local adb server (`127.0.0.1:5037`). With wireless debugging, adb connects to the device over
  your local network.
- **Network**: the only download is Android SDK Platform-Tools from `dl.google.com`, and only when
  you ask for it (when no `adb` is installed). It is saved in the app's own Application Support
  folder.
- **Files**: it reads and writes only the files you choose to transfer, plus temporary files
  (`.*.xfer-part` next to a download in progress, and its own temporary folder).
- **Sandbox**: the app runs without the App Sandbox, because it needs the adb server socket and
  raw USB access. To take the MTP interface from macOS's `ptpcamerad` it may end that process
  (it is restarted by the system), and on request it can turn `ptpcamerad` off for your user
  with `launchctl`. Both are described in [docs/QUIRKS.md](docs/QUIRKS.md) (H1–H3).

## Reporting a vulnerability

Please report security issues privately through GitHub's **Report a vulnerability** (Security
Advisories) on this repository rather than in a public issue. Only the latest release and the
default branch are supported.

## Disclaimer

SolidFerry is provided "as is", without warranty of any kind, under the [MIT License](LICENSE).
Moving files between devices can lose data if a device misbehaves; keep backups of anything you
can't afford to lose.
