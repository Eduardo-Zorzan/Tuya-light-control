# Tasks

## 1. Project scaffolding

- [x] 1.1 Create the local Swift package `Packages/TuyaLocal` (library `TuyaLocal`, executable `tuya-probe`, test target using Swift Testing, test-only dependency `swift-clocks`) and the Xcode app project `catLight` (Swift 6 language mode, macOS 14 deployment target) depending on it; verify `swift build` and `swift test` in the package and `xcodebuild -scheme catLight build` all succeed
- [x] 1.2 Configure the app as a menu bar agent (`LSUIElement = YES`), add `NSLocalNetworkUsageDescription`, enable App Sandbox with network client/server entitlements and Hardened Runtime; verify running the app from Xcode shows no Dock icon and `codesign -d --entitlements - <app>` lists both network entitlements
- [x] 1.3 Add a `Log` helper over `os.Logger` with categories (connection, discovery, cloud, ui) that never accepts secret values, and a lint/format setup (`swift-format` config) run via a `Makefile` target `make check` that runs format lint and all tests; verify `make check` passes on the scaffold
- [x] 1.4 Write `README.md` with prerequisites (Xcode 16+, macOS 14+) and build/test/run commands; verify the commands run as written

## 2. Tuya local protocol (`Packages/TuyaLocal`)

- [x] 2.1 Implement 3.3 framing (`0x55AA` prefix/suffix, seq, command, length, CRC32 via zlib) and AES-128-ECB payload crypto via CommonCrypto with the version header; verify with Swift Testing unit tests using encode/decode vectors taken from tinytuya
- [x] 2.2 Implement 3.4 session key negotiation (commands 3/4/5, nonces, CryptoKit HMAC-SHA256) and HMAC-protected frames; verify with unit tests against recorded negotiation vectors, including rejection of a wrong local key
- [x] 2.3 Implement 3.5 `0x6699` framing with CryptoKit `AES.GCM` using the negotiated session key; verify with unit tests for encode/decode and tag-mismatch rejection
- [x] 2.4 Implement the async `TuyaClient` over `NWConnection` (3 s connect timeout, TCP keepalive, frame reassembly): connect, negotiate, `queryDPs`, `setDPs`, `heartbeat`, and an `AsyncStream` of device-pushed `STATUS` frames, with typed errors (`timeout`, `invalidKey`, `connectionRefused`, `localNetworkDenied`, `protocol`); verify with tests against an in-process fake device server (`NWListener` on localhost) for 3.3/3.4/3.5
- [x] 2.5 Implement version auto-detection (try discovery version first, else 3.5 → 3.4 → 3.3) returning the working version; verify with fake-server tests that a 3.4-only device resolves to 3.4
- [ ] 2.6 Implement the `tuya-probe` executable (`swift run tuya-probe <ip> <deviceID> <localKey>`) and run it against the user's real Positivo light; verify it prints the protocol version and DP map, and record the observed version, DP profile and value ranges in `Packages/TuyaLocal/DEVICES.md`

## 3. Local discovery

- [x] 3.1 Implement UDP discovery listeners on ports 6666, 6667 (decrypt with the well-known UDP key) and 7000 (3.5) as an `AsyncStream<DiscoveredDevice>`, first with `NWListener` and falling back to BSD sockets with `SO_REUSEADDR`/`SO_REUSEPORT` if broadcasts are not delivered; verify with unit tests on captured broadcast payloads and by seeing the real light announced by `tuya-probe --discover`
- [x] 3.2 Handle port-in-use and permission errors without crashing (log and expose a "discovery unavailable" flag); verify with a test that binds the port first

## 4. Connection manager (device actors)

- [x] 4.1 Implement the `DeviceConnection` actor with the Idle/Connecting/Connected/Backoff/Error state machine, injected `Clock`, and `AsyncStream`s for `ConnectionStatus` and `ReportedState`; verify with fake-server tests that status transitions are published in order
- [x] 4.2 Implement heartbeat every 10 s with 5 s reply timeout plus TCP keepalive; verify with a fake server that stops responding and a `TestClock` that status becomes Offline within 15 s
- [x] 4.3 Implement exponential backoff with ±20% jitter capped at 30 s, reset on success, and `reconnectNow()` cancelling the wait; verify with `TestClock` tests that intervals never exceed 30 s and that `reconnectNow()` reconnects immediately
- [x] 4.4 Implement desired-state coalescing (merge patches, send dirty DPs at most every 80 ms in one frame, latest-wins); verify a test sending 50 brightness patches results in few frames and a final device value equal to the last patch
- [x] 4.5 Implement confirmation with 5 s timeout, single resend on a fresh connection, `.applyFailed` on second failure, and replay of desired state younger than 60 s after reconnect; verify with fake-server tests for silent-drop, recovery and stale-desire discard
- [x] 4.6 Map errors to user-facing statuses (invalid key, connection refused/another client, local network permission denied, unsupported protocol); verify each with a fake-server or injected-error test
- [x] 4.7 Implement the `DeviceManager` actor owning one `DeviceConnection` per light with fan-out for "all lights" and address updates from discovery; verify a test where one of three fake devices is down still applies to the other two immediately

## 5. Light model and DP mapping

- [x] 5.1 Implement `LightState`, DP profile detection (v2 DPs 20–24 vs legacy 1–5) and conversions (HSV ↔ `colour_data_v2` / legacy colour hex, brightness % ↔ `bright_value`/`v`, Kelvin ↔ `temp_value` using the per-light range); verify round-trip unit tests for both profiles and range edges
- [x] 5.2 Implement intent → DP patch builders (power, color with `work_mode` in the same frame, white with temperature, brightness per mode, turn-on-on-change rule, Kelvin clamping); verify unit tests covering each light-control and scene clamping scenario

## 6. Persistence, secrets and device management (app target)

- [x] 6.1 Implement `ConfigStore` (`Codable` JSON in Application Support with atomic writes: lights, active selection, favorites, last known state, preferences); verify tests for save/load round trip and recovery from a corrupted file
- [x] 6.2 Implement `KeychainStore` for local keys and the optional Tuya Access Secret using the Security framework; verify a test that saves, reads and deletes a key, and that `config.json` contains no key after adding a light
- [x] 6.3 Implement manual add/edit/remove of lights with validation (required name, device ID, local key) that starts/stops/updates the matching `DeviceConnection`; verify tests for missing-field rejection and that removal shuts down the connection and deletes the Keychain entry
- [x] 6.4 Implement the Tuya OpenAPI client with `URLSession` (signed requests, token, list devices with local keys, device specifications for Kelvin range, region selection) and "refresh keys"; verify with unit tests on request signing against Tuya's documented example and with a mocked `URLProtocol` for success and invalid credentials
- [x] 6.5 Implement active selection (single light or all lights) persisted in config; verify a test that the selection survives a reload

## 7. App shell (status item, popover, system events)

- [ ] 7.1 Implement the `NSStatusItem` with the cat-bulb template image plus a colored status dot (current color, gray when off or offline) and a right-click `NSMenu` with "Sair"; verify manually that the dot changes color when the light changes
- [ ] 7.2 Implement the `NSPopover` (`.transient`, dark appearance, fixed 356 pt width, content size tracking tab changes) hosting the SwiftUI root, toggled by left click, closed on outside click, app switch and Escape; verify manually that it opens in under 300 ms and closes on outside click
- [ ] 7.3 Implement the `HotKey` wrapper over Carbon `RegisterEventHotKey` and register ⌘⇧L to toggle the popover; verify manually from another focused app
- [ ] 7.4 Implement launch at login with `SMAppService.mainApp` (default on after first setup) and Quit that shuts down connections without sending commands; verify manually in System Settings → General → Login Items and that the light state is unchanged after quit
- [ ] 7.5 Observe `NSWorkspace.didWakeNotification` and `NWPathMonitor` changes to call `reconnectNow()` on all connections, and trigger reconnect/refresh on `popoverWillShow`; verify manually by sleeping the Mac and toggling Wi-Fi that the light reconnects within seconds (check Console.app for the trigger log)
- [x] 7.6 Implement the `@MainActor @Observable AppModel` consuming connection streams and exposing intents for lights, favorites, scenes, devices and settings; verify with unit tests driving `AppModel` against a fake `DeviceManager`

## 8. Popover UI — header and Luz tab (SwiftUI)

- [x] 8.1 Build the popover chrome from the mockup in SwiftUI (header with light name and connection dot, power switch, cat-bulb emblem with colored halo, title, segmented Luz/Cenas/Ajustes tabs, grouped card style); verify visually against the mockup HTML side by side, using SwiftUI previews
- [ ] 8.2 Render cached state instantly on open and show offline/not-current and "change not applied" indicators from `AppModel`; verify manually by unplugging the light while the popover is open
- [ ] 8.3 Implement the color wheel (HSV disk rendered once to a `CGImage`, drag gesture, cursor overlay), swatch, editable hex field with validation, and the Cor RGB / Branco CCT mode toggle with per-mode memory; verify manually on the real light and with a unit test for hex parsing/validation
- [ ] 8.4 Implement the custom brightness and temperature sliders (drag + keyboard arrows, fill takes current color, Kelvin gradient, label Quente/Neutro/Frio over the light's range) and the Vela/Leitura/Foco presets, with drag-time suppression of incoming state and 50 ms intent throttling; verify manually that a fast drag is smooth and the light settles on the final value

## 9. Favorites and scenes

- [x] 9.1 Implement `Favorites` logic (defaults, save to front, dedupe, max 12 dropping oldest, delete, persist via `ConfigStore`) with unit tests for every color-favorites scenario
- [ ] 9.2 Implement the favorites grid view (apply, hover/focus-revealed delete, count label, empty message, "✓ Salva!"/"✓ Já salva" feedback); verify manually and that favorites survive an app restart
- [x] 9.3 Implement the scene table and `applyScene` as one desired-state patch with clamping and active-scene tracking, with unit tests for each scene and for clearing the highlight on another change
- [ ] 9.4 Implement the Cenas tab grid with active-scene highlight; verify manually that each scene changes the real light and the Luz tab reflects it

## 10. Ajustes tab and first-run setup

- [ ] 10.1 Implement the Ajustes tab: active light picker with "Todas as luzes", per-light list with live status, add/edit/remove sheets, "Iniciar com o macOS" toggle, version, shortcut hint and "Sair"; verify manually each control changes state and persists across restart
- [ ] 10.2 Implement the first-run setup view (shown when no lights are registered) with "Importar do Tuya IoT" (Access ID/Secret/region, device selection list, remember-secret option, guidance for linking the Positivo or Smart Life account) and "Adicionar manualmente"; verify manually by importing the user's real light from a fresh config
- [ ] 10.3 Show the Local Network permission-denied view with a button opening System Settings → Privacy & Security → Local Network (`x-apple.systempreferences:` URL); verify manually by denying the permission

## 11. Integration checks on real hardware

- [ ] 11.1 Run the full connection-resilience checklist on the real light(s) — power-cycle the light, reboot the router, sleep/wake the Mac, change the light's IP via DHCP, run with internet disconnected, and enter a wrong key — and verify each recovers or reports as specified in `specs/tuya-device-connection`; record results in `docs/connection-test-log.md`
- [ ] 11.2 Build a release archive (`xcodebuild -scheme catLight -configuration Release archive`), export the app, install it in `/Applications`, and verify launch at login, ⌘⇧L, and multi-light "Todas as luzes" control work from the installed app
