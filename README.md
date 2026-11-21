# Tuya Light Control

A native macOS menu bar app (Swift, SwiftUI + AppKit) that controls Tuya-based lights (e.g. Positivo
Casa Inteligente RGB) directly over the local network, without the cloud for everyday control.

Design and requirements live in [`openspec/changes/add-macos-menubar-light-controller`](openspec/changes/add-macos-menubar-light-controller).

## Layout

```
Packages/TuyaLocal/   Swift package: Tuya local protocol 3.3/3.4/3.5, discovery, connection actors,
                      light/DP mapping, and the `tuya-probe` command line tool (no UI)
catLight/              Xcode app target (project: catLight.xcodeproj): status item, popover, SwiftUI views, persistence
```

## Prerequisites

- macOS 14 or later
- **Xcode 16+** (developed with Xcode 27.2), selected with `xcode-select`, license accepted and
  first-launch components installed (`sudo xcodebuild -license accept`, `sudo xcodebuild -runFirstLaunch`)
- The `TuyaLocal` package alone only needs a Swift 6 toolchain

## Build, test, lint

```bash
make check          # format lint + all tests
```

```bash
make lint           # swift format lint --strict
```

```bash
make format         # apply formatting in place
```

```bash
make test-package   # the TuyaLocal tests (swift test)
```

Without `make`, the package and the app build and test with:

```bash
cd Packages/TuyaLocal && swift build && swift test
```

```bash
xcodebuild -project catLight.xcodeproj -scheme catLight build
```

```bash
xcodebuild -project catLight.xcodeproj -scheme catLight test
```

## Running the app

Builds and launches the menu bar app (no Dock icon). Until a Quit menu exists, stop it from a terminal:

```bash
make run
```

```bash
pkill -x catLight
```

## Trying it on a real light

The light and the Mac must be on the same LAN. The first LAN access asks for macOS **Local Network**
permission (for the terminal when using `tuya-probe`).

Listen for the light's UDP broadcasts (shows device id, IP and protocol version):

```bash
make discover
```

Probe a light with its device ID and local key (the local key comes from the Tuya IoT platform;
it is never logged):

```bash
make probe IP=192.168.0.20 ID=<deviceID> KEY=<localKey>
```

This prints the protocol version that worked and the datapoint map. Record the result in
`Packages/TuyaLocal/DEVICES.md`.

## Security notes

- Local keys and the Tuya Access Secret are meant for the macOS Keychain, never `config.json` or logs.
- `Log` (in `TuyaLocal`) only accepts constant messages plus a device id, address and error, so secrets
  cannot be passed to the logger by accident.
