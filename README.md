# rev-hardware-client.mjs

This repo has a Node.js command line tool and SwiftUI app for updating REV Driver Hubs, Control Hubs, and Expansion Hubs.
It runs the same OS and firmware update steps as the official REV Hardware Client, but is designed to
work on macOS (RHC v1 doesn't have MacOS support).

CLI still works for Linux users, documented below.

Note: This tool does not support all the features of the full REV Hardware Client. See the [Not supported](#not-supported) section below for details. It might be possible to extract those features as well, but no effort has been made to do so here.

## How it works

REV Hardware Client communicates over ADB using USB, with plain HTTP.

1. Runs `adb devices` to find devices on the RC network
2. `adb shell getprop <key>` to differentiate DS from a
   Control Hub
2. `adb forward tcp:<local> tcp:8080` (and `tcp:8081`) to expose onto localhost
3. Downloads the update file from REV's public manifest
   (`https://www.revrobotics.com/content/sw/rev-hw-client/main.json`, then the `RevHub`
   plugin JSON) and checks its SHA-256
4. Sends this file via POST to the hub's REST API

## Requirements

- `adb` on `PATH`. On macOS, install it with `brew install android-platform-tools`, or [here](https://developer.android.com/tools/releases/platform-tools)
- Node.js 18+.
- `dfu-util`, only for SPARK MAX, SPARK Flex and Servo Hub firmware: `brew install dfu-util`.
- A Driver Hub or Control Hub plugged into the Mac over USB.

## CLI Usage

```
./rev-hardware-client.mjs list
# prints each device ID and type, for example "R3CN9026H8P    driver-hub"
# add --json to list, discover-hubs, wifi, info, logs, settings, dfu-list or version

./rev-hardware-client.mjs update driver-hub-os
# dry run, prints the version and file, and does not contact the hub

./rev-hardware-client.mjs update driver-hub-os --yes
# uploads the file and starts the OTA update

./rev-hardware-client.mjs update control-hub-os --yes

./rev-hardware-client.mjs discover-hubs
# Control Hub only. Lists serials you can pass to `update hub-firmware`.
# "(embedded)" is the Control Hub's own onboard firmware.

./rev-hardware-client.mjs update hub-firmware --serial "(embedded)" --yes
./rev-hardware-client.mjs update hub-firmware --serial <expansion-hub-serial> --yes

./rev-hardware-client.mjs wifi
# checks whether this Mac is on a Robot Controller network, pings 192.168.43.1,
# and checks the RC web server on port 8080

./rev-hardware-client.mjs info
# installed vs latest OS, app and firmware versions, and which have updates

./rev-hardware-client.mjs update robot-controller-app --yes   # Control Hub
./rev-hardware-client.mjs update driver-station-app --yes     # Driver Hub
# installs the FTC app from REV's manifest over adb, then opens it

./rev-hardware-client.mjs logs
# saves RC/DS, updater and Wi-Fi logs, match logs and logcat to ~/Downloads

./rev-hardware-client.mjs settings
./rev-hardware-client.mjs settings --name 1234-RC --password <pw> --channel <channel> --yes
# Control Hub only, needs the Robot Controller app running. Same request as the
# hub's Manage page. The hub restarts its Wi-Fi after a change.

./rev-hardware-client.mjs dfu-list
./rev-hardware-client.mjs update spark-max-firmware --yes
./rev-hardware-client.mjs update spark-flex-firmware --yes
./rev-hardware-client.mjs update servo-hub-firmware --yes
# needs dfu-util. Hold the device's mode button while plugging in USB to enter
# DFU mode. Pass --serial if more than one device is in DFU mode.

./rev-hardware-client.mjs version --check
# checks GitHub releases for a newer version of this tool
```

If more than one device is attached, pass `--adb-id <id>` to any command. Get the ID
from `list`.

The tool caches verified downloads in `~/.rhc-mac-tool/downloads/`.

## Mac (native) app

`app/` is a simple MacOS-only SwiftUI app.

```
./app/build.sh
open "app/build/REV Hub Updater.app"
```
Has same functionality as just using this service with the commands. Device pages show
installed and latest versions, hub settings and log saving; the sidebar has Wi‑Fi and
SPARK & Servo Hub pages.

macOS hides the Wi‑Fi network name unless an app has location access. The CLI can't
show it; the app asks for permission the first time you click **Show network name**.

## Not supported

These flows depend on Windows-only native modules or on hardware that was not available
for testing.

- **SPARK settings** (motor type, limits, and so on). DFU firmware flashing is supported (untested on hardware), but
  configuration uses REV's undocumented USB protocol.
- **Hardware testing** (spinning motors, reading sensors).
- **Expansion Hub firmware over a direct USB cable**, as opposed to through a Control
  Hub. This uses the `@rev-robotics/expansion-hub-ftdi` native module.
- **Firmware for devices on a hub's CAN bus**, such as a chained SPARK MAX. REV Hardware
  Client loads these with `runBootloader` and CAN messages, not the hub's REST API. This
  uses the `@rev-robotics/can-bridge` native module.

REV Hardware Client 1.7.6 ships only Windows builds of both native modules. Before
writing code for either flow, check REV's GitHub for macOS builds. Without one, the
native library has to be built from source.

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for details.
