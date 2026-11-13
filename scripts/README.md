# scripts

| Script | What it's for |
|---|---|
| `build-dmg.sh [vX.Y.Z]` | Release build of the app, ad-hoc signed, packaged as `build/SolidFerry-<version>.dmg`. The release workflow runs this same script. |
| `queue-test.sh A B` | The transfer queue end to end on two devices: downloads, uploads and device-to-device copies with each conflict policy, checked by md5 on both sides. |
| `two-jobs-test.sh A B` | Two jobs running at once: copies in both directions between two devices, and two devices downloading files of the same names into one Mac folder. |
| `pause-test.sh SERIAL` | Pausing and resuming jobs that replace files, at several moments; afterwards every file must be whole and nothing temporary left. |
| `bigtest.sh SERIAL adb\|mtp DIR` | Many files on one device: 8,000 photos and 2,000 documents downloaded, re-downloaded with each skip rule, uploaded, copied, merged and moved. |

The test scripts drive a Debug build of the app (`make build`) through its development launch
arguments (`-dev.*`, listed at the top of `App/DevelopmentLaunchArguments.swift`) and check the
results through `adb`, so the devices need USB debugging on. A device's connection is chosen per
run: `SERIAL:adb` or `SERIAL:mtp`. Quit the app before running them. See
[docs/DEVICE_TESTS.md](../docs/DEVICE_TESTS.md) for when to run which.

**Safety**: they only create and delete their own `/sdcard/Download/xfer-*` folder on each
device, with generated files, and a temporary folder on the Mac. `bigtest.sh` keeps its source
files in `DIR/src` for the next run (the setup command is in DEVICE_TESTS.md); delete `DIR` when
you're done.
