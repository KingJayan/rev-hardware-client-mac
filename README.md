# rev-hardware-client.mjs

This repo houses `rev-hardware-client.mjs`, a Node.js command line tool that updates REV Driver Hubs, Control Hubs, and Expansion Hubs.
It runs the same OS and firmware update steps as REV Hardware Client, but is designed to
work on macOS. No Windows or virtualization layers.

## Why this tool exists

The Rev Hardware Client only works on Windows. That's despite the fact that it is built on Electron, a widely used application framework notable for its cross-platform application support. ¯\_(ツ)_/¯

This project extracts the important bits of FTC-specific functionality from the REV Hardware Client and reimplements them in to be generic and cross-platform, specifically for macOS and Linux users.

Note: This tool does not support all the features of the full REV Hardware Client. See the [Not supported](#not-supported) section below for details. It might be possible to extract those features as well, but no effort has been made to do so here.

## How it works

REV Hardware Client talks to these hubs with ADB over USB and then plain HTTP.

1. `adb devices` finds the hub. `adb shell getprop <key>` differentiates a Driver Hub from a
   Control Hub.
2. `adb forward tcp:<local> tcp:8080` (and `tcp:8081`) exposes the hub's web server on
   localhost.
3. The tool downloads the update file from REV's public manifest
   (`https://www.revrobotics.com/content/sw/rev-hw-client/main.json`, then the `RevHub`
   plugin JSON) and checks its SHA-256.
4. The tool sends the file as a `multipart/form-data` POST to the hub's REST API.
   The endpoints are `/uploadDriverHubOta`, `/uploadControlHubOta`, or
   `/uploadExpansionHubFirmware` followed by `/performRevFirmwareUpdate`.

These steps come from the main process source in REV Hardware Client 1.7.6
(`resources/app.asar`). This path uses no native Windows binary such as CANBridge,
FTDI D2XX, or `dfu-util-static.exe`.

## Requirements

- `adb` on `PATH`. On macOS, install it with `brew install android-platform-tools`.
- Node.js 18 or later.
- A Driver Hub or Control Hub plugged into the Mac over USB.
- Only one client per hub. REV Hardware Client and this tool both use `adb forward`, so
  running both against the same hub causes conflicts.

## Usage

```
./rev-hardware-client.mjs list
# prints each device ID and type, for example "R3CN9026H8P    driver-hub"

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
```

If more than one device is attached, pass `--adb-id <id>` to any command. Get the ID
from `list`.

The tool caches verified downloads in `~/.rhc-mac-tool/downloads/`.

## Not supported

These flows depend on Windows-only native modules or on hardware that was not available
for testing.

- **SPARK MAX, SPARK Flex, and Servo Hub firmware over DFU.** REV Hardware Client runs a
  bundled `dfu-util-static.exe`. Homebrew's `dfu-util` may work in its place. Nobody has
  traced or tested the arguments that `runDfuUtil` in `main.js` builds.
- **Expansion Hub firmware over a direct USB cable**, as opposed to through a Control
  Hub. This uses the `@rev-robotics/expansion-hub-ftdi` native module.
- **Firmware for devices on a hub's CAN bus**, such as a chained SPARK MAX. REV Hardware
  Client loads these with `runBootloader` and CAN messages, not the hub's REST API. This
  uses the `@rev-robotics/can-bridge` native module.

REV Hardware Client 1.7.6 ships only Windows builds of both native modules. Before
writing code for either flow, check REV's GitHub for macOS builds. Without one, the
native library has to be built from source.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

This tool is provided as-is, without any warranty. Use it at your own risk. It worked during development and uses battle-tested tools (adb, nodejs), standard protocols (HTTP), and interacts with the same interfaces the official client does. But, it's still a third-party tool writing updates to proprietary hardware. We've run it and we're still here. But, we're weird people who don't fret about breaking things. You do you.
