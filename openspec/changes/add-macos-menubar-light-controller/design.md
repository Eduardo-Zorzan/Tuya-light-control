# Design

## Context

Greenfield repository (only a README and the OpenSpec scaffold). The UI target is the HTML mockup `astralight_controle_rgb_para_macos.html` (Portuguese UI, ~360 px wide popover with Luz / Cenas / Ajustes tabs, dark glass style). The lights are Positivo Casa Inteligente RGB+CCT bulbs/strips, which are Tuya OEM devices (Tuya category `dj`), reachable on TCP port 6668 with the Tuya local protocol. Each device needs its device ID and *local key* to be controlled locally; the local key can only be obtained from Tuya's cloud. The user chose LAN-only control, multi-light support, and Swift as the implementation language. Motivation and scope: see proposal.md; behavior: see `specs/`.

## Goals / Non-Goals

**Goals:**
- A fully native macOS app in Swift that reproduces the mockup closely using SwiftUI inside a real AppKit popover.
- A connection layer that is self-healing and observable: every failure has a visible status and an automatic recovery path.
- Testable protocol and connection code (encode/decode against known vectors, time-controlled reconnect tests) independent of the UI.

**Non-Goals:**
- Signed/notarized distribution and auto-update (a local Xcode archive is enough for now).
- Supporting non-light Tuya categories or macOS versions older than 14.

## Decisions

### D1. Swift 6 + SwiftUI hosted in an AppKit `NSStatusItem` / `NSPopover`
- Target macOS 14 (Sonoma) and later, Swift 6 language mode with strict concurrency. macOS 14 gives the Observation framework (`@Observable`), `SMAppService`, and modern SwiftUI `Canvas`.
- `LSUIElement = YES` in Info.plist: no Dock icon, not in the app switcher.
- Menu bar: an `NSStatusItem` whose button image is the cat-bulb as a template image composited with a colored status dot (redrawn when color/power/status changes). Left click toggles an `NSPopover` (`behavior = .transient`, dark appearance) hosting the SwiftUI root view via `NSHostingController`; right click shows an `NSMenu` with "Sair". `NSPopover` provides the arrow, vibrancy, anchoring, and dismissal on outside click / app switch natively; Escape is handled with `cancelOperation`.
- UI: SwiftUI views rebuilt from the mockup — segmented tab bar, grouped cards, custom slider (track, colored fill, thumb, keyboard steps), Kelvin gradient track, macOS-style switch, color wheel drawn once into a `CGImage` (HSV disk) with a drag gesture and cursor overlay, favorites grid with hover-revealed delete, scene grid.

Alternatives considered:
- **SwiftUI `MenuBarExtra(.window)`**: simplest, but it cannot be opened/closed programmatically (blocks the ⌘⇧L toggle and "open → reconnect" hook), has no right-click menu, and offers limited control over the icon.
- **Rust + Tauri (previous plan)**: reuses the HTML mockup directly, but the popover is a web view imitating a popover, adds a JS/Node toolchain, and isn't native; dropped at the user's request.
- **Pure AppKit views**: more code than SwiftUI for the same look; SwiftUI is used for content, AppKit only for the status item and popover.

### D2. Own Tuya local protocol implementation in a local Swift package
Layout:

```
Packages/TuyaLocal/          # SwiftPM library: framing, crypto, session, discovery, connection actor (no UI)
  Sources/TuyaLocal/
  Sources/tuya-probe/        # executable for testing against a real light
  Tests/TuyaLocalTests/
catLight/                         # Xcode app target: AppKit shell, SwiftUI views, app model, persistence, cloud import
catLightTests/
catLight.xcodeproj
```

`TuyaLocal` implements:
- **3.3**: `0x55AA` frames, AES-128-ECB with the local key (CommonCrypto `CCCrypt` with `kCCOptionECBMode` — CryptoKit has no ECB), CRC32 (zlib `crc32`), version header on non-query commands.
- **3.4**: session key negotiation (commands 3/4/5 with local/remote nonces, `HMAC<SHA256>` from CryptoKit), then AES-ECB with the session key and HMAC-SHA256 frame integrity.
- **3.5**: `0x6699` frames, `AES.GCM` (CryptoKit) with the negotiated session key.
- Commands: `DP_QUERY` (10), `CONTROL`/`CONTROL_NEW` (7/13), `HEART_BEAT` (9), `STATUS` (8) pushes, `DP_QUERY_NEW` (16) for 3.4+.
- **Transport**: `NWConnection` (Network.framework) TCP with a 3 s connect timeout and TCP keepalive (`NWProtocolTCP.Options.enableKeepalive`); a small async wrapper turns its callbacks into `async` send/receive with frame reassembly.
- **Discovery**: UDP listeners on 6666 (plain), 6667 (encrypted with the well-known UDP key, MD5 via `Insecure.MD5`) and 7000 (3.5), yielding `{deviceID, ip, version}` as an `AsyncStream`.

Reference implementations for behavior and test vectors: tinytuya (Python) and tuyapi (JS). Owning the protocol (~1.5k lines) lets the connection behavior be designed rather than inherited; there is no maintained Swift Tuya library.

### D3. One Swift actor per light owning its connection
Each registered light gets a `DeviceConnection` actor that is the only owner of that light's `NWConnection`. It runs a state machine:

```
 Idle ──connect──▶ Connecting ──negotiated──▶ Connected
   ▲                   │                         │ heartbeat timeout / socket error /
   │                   ▼ fail                    ▼ wake / network change
   └──── Backoff(n) ◀──┴────────────────────── Disconnected
```

- Inputs are actor methods (`setDesired(_ patch:)`, `refresh()`, `reconnectNow()`, `updateAddress(_:)`, `updateKey(_:)`, `shutdown()`); a long-running `Task` inside the actor drives the state machine.
- **Desired-state coalescing** (spec: Command coalescing): the actor keeps `desired: [DP: Value]` with a timestamp and a dirty set. Patches merge into `desired`; a send loop transmits dirty DPs at most every 80 ms in one `CONTROL` frame. Values overwritten before sending are never sent — latest-wins, not a queue.
- **Confirmation**: after a send the actor waits up to 5 s for an ack or a `STATUS` containing the values. On timeout it marks the connection dead, reconnects, and resends the current `desired` once; a second failure emits `.applyFailed`.
- **Offline desires** (spec: Commands while offline): `desired` survives reconnects and is replayed if younger than 60 s, otherwise dropped.
- **Heartbeat**: every 10 s while idle; any frame resets the timer; no reply in 5 s ⇒ dead. TCP keepalive is a second line of defense.
- **Backoff**: `min(30s, 1s · 2^n) ± 20% jitter`, reset on successful negotiation; `reconnectNow()` cancels the sleeping task. Auth errors (decrypt/HMAC failure during negotiation) use the same backoff but report `.error(.invalidKey)`.
- **Time is injected** as `any Clock<Duration>`; tests use `TestClock` from pointfree's `swift-clocks` (test-only dependency) to verify heartbeat and backoff timing instantly.
- **Status out**: each actor exposes `AsyncStream<ConnectionStatus>` and `AsyncStream<ReportedState>`; the app model consumes them on the main actor.
- A `DeviceManager` actor owns all `DeviceConnection`s; "All lights" fans out `setDesired` to each without awaiting the others (spec: Independent connections per light).

Alternative: a shared connection pool with request/response continuations — harder to reason about with device-initiated status pushes and per-session keys; per-device actors keep state isolated and data-race-free under Swift 6 checking.

### D4. System event triggers
- **Wake from sleep**: `NSWorkspace.didWakeNotification` → drop sockets and `reconnectNow()` on all connections.
- **Network change**: `NWPathMonitor`; on a path change (interface or status), `reconnectNow()` on all connections. The path's `unsatisfiedReason == .localNetworkDenied` (macOS 14+) and `NWError` policy-denied errors map to the "Local Network permission needed" status.
- **Popover opened**: `popoverWillShow` → `reconnectNow()` for non-connected lights and `refresh()` (DP query) for connected ones.
- **Discovery**: the listener runs for the app lifetime; a known device ID seen at a new IP (or with a version) triggers `updateAddress`, which reconnects there.

### D5. Light model and DP mapping
Internal model (`LightState`): `power: Bool`, `mode: .color | .white`, `hsv: (h 0–360, s 0–1000, v 0–1000)`, `whiteBrightness: 10–1000`, `temp: 0–1000`, plus per-light `kelvinRange` (default 2700–6500) for mapping UI Kelvin ↔ Tuya `temp_value`.

DP profile, detected from the first DP query (spec: Light capability mapping):
- **v2** (common on Positivo): 20 `switch_led`, 21 `work_mode` (`white`/`colour`), 22 `bright_value_v2` (10–1000), 23 `temp_value_v2` (0–1000), 24 `colour_data_v2` (12 hex chars `HHHHSSSSVVVV`).
- **legacy**: 1 switch, 2 mode, 3 bright (25–255), 4 temp (0–255), 5 colour (14 hex `rrggbb0hhhssvv`).

Mapping lives in `TuyaLocal` (`LightDP.swift`) with unit tests both ways. UI brightness % maps to `v` in color mode and `bright_value` in white mode (spec: Brightness control). A color change in color mode sends `work_mode=colour` + `colour_data` in one frame to avoid a visible flash.

### D6. Persistence, secrets, shortcut, login item, sandbox
- Non-secret config: `Application Support/<bundle-id>/config.json` via `Codable` with atomic writes (`Data.write(options: .atomic)`) — lights (id, name, ip, version, DP profile, Kelvin range, product id), active selection, favorites, last known state per light, preferences.
- Secrets: Keychain generic passwords via the Security framework (`SecItemAdd/CopyMatching/Update/Delete`), service `<bundle-id>`, accounts `localkey:<deviceID>` and `tuya-cloud:<accessID>`, accessibility `kSecAttrAccessibleAfterFirstUnlock` so the app works at login.
- Logging: `os.Logger` (unified logging). Keys, secrets and payload ciphertext are never passed to the logger; device IDs use `privacy: .private`.
- Global shortcut ⌘⇧L: Carbon `RegisterEventHotKey` (no Accessibility permission needed), wrapped in a small `HotKey` type.
- Launch at login: `SMAppService.mainApp.register()/unregister()`; the toggle reads `SMAppService.mainApp.status`.
- App Sandbox enabled with `com.apple.security.network.client` and `com.apple.security.network.server` (needed to bind UDP discovery ports); Info.plist has `NSLocalNetworkUsageDescription`. Hardened Runtime on.

### D7. Tuya IoT Cloud import (one-time)
`URLSession` against Tuya OpenAPI: get token (`/v1.0/token?grant_type=1`), list devices for the linked app user (`/v1.0/users/{uid}/devices` or `/v1.0/iot-01/associated-users/devices`), and per-device details including `local_key`, `product_id`, and the DP specification (`/v1.0/devices/{id}/specifications`) to get the temperature range when available. Requests use Tuya's HMAC-SHA256 signing (CryptoKit). Regions: Western America, Eastern America, Central Europe, Western Europe, India, China (Brazil accounts are normally "Western America"). The Access Secret is stored in Keychain only if the user ticks "remember", so "refresh keys" doesn't need re-entry.

### D8. App state flow
An `@MainActor @Observable` `AppModel` is the single source of truth for the UI: per-light `ConnectionStatus`, `ReportedState`, cached last-known state, selection, favorites, active scene, preferences. It consumes the connection actors' streams and exposes intents (`setPower`, `setColor`, `setWhite`, `setBrightness`, `applyScene`, `saveFavorite`, …) that build DP patches and call `DeviceManager`. SwiftUI views observe `AppModel` directly. During an active drag a view holds a local "editing" value and ignores incoming state for that control (spec: State synchronization), and throttles intents to one per 50 ms; the actor coalesces further. The popover renders the cached state instantly on open (spec: Popover toggle). Scenes are a constant table and favorites logic lives in a plain struct, both unit-tested.

## Risks / Trade-offs

- [Local key acquisition for an OEM app] Tuya IoT "link app account" officially supports Tuya Smart / Smart Life accounts; a Positivo Casa Inteligente account may not link. → Document the fallback in the setup view: pair the lights in the Smart Life app instead, or enter keys obtained by other means manually.
- [Single local connection slot] Many Tuya devices accept only one local TCP client; another LAN controller (Home Assistant, tinytuya scripts) can block us. → Distinct "connection refused" status with a hint; backoff keeps retrying.
- [Protocol 3.5 details] 3.5 is less documented. → Port behavior from tinytuya with recorded test vectors; validate early on the real light (task 2.6 checks the actual device's version first).
- [UDP broadcast reception with Network.framework] `NWListener` on UDP ports may not deliver broadcast datagrams reliably, or may conflict with other apps bound to the same ports. → Prototype in task 3.1; fall back to a BSD `socket`/`recvfrom` listener with `SO_REUSEADDR`/`SO_REUSEPORT` wrapped in a `DispatchSource`.
- [AES-ECB not in CryptoKit] → Use CommonCrypto for ECB only; CryptoKit for GCM, HMAC and MD5.
- [Kelvin range unknown] Positivo product specs may not expose the CCT range. → Default 2700–6500K, user-overridable per light.
- [Sandbox + Local Network permission] macOS blocks LAN access until approved, and the prompt only appears on first LAN access. → Trigger a connection attempt right after setup so the prompt appears in context, and show the permission-needed view when `NWPathMonitor`/errors report denial.
- [SwiftUI inside NSPopover sizing] Popover content size must track tab changes. → Fixed width (356 pt) and `preferredContentSize` updated from the hosting controller's fitting size on tab change.

## Migration Plan

Not applicable (new app). Rollback is uninstalling the app; it does not alter the lights' configuration or pairing.

## Open Questions

- Exact Kelvin range and protocol version of the user's Positivo lights — discovered on the real device during task 2.6; only affects defaults, not behavior.
- App name is **catLight** (bundle id `com.catlight.app`, chosen by the user); the mockup's "AstraLight RGB" name is not used.
