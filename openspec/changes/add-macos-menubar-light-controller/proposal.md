# Proposal

## Why

The Positivo Casa Inteligente RGB lights (Tuya-based hardware) are only controllable through the vendor's phone app, which is slow to open and unreliable at keeping a connection to the lights. A macOS menu bar app that talks to the lights directly over the local network gives instant, always-available control from the desktop and lets us own the connection handling instead of depending on Tuya's cloud.

## What Changes

- New native macOS menu bar application (no Dock icon) written in Swift (SwiftUI + AppKit), opening a popover from a menu bar icon, with the look and layout of the reference mockup (`astralight_controle_rgb_para_macos.html`: tabs Luz / Cenas / Ajustes, dark glass style, cat-bulb icon).
- Direct LAN control of Tuya lights using the Tuya local protocol (versions 3.3, 3.4 and 3.5), with no cloud round trip for everyday commands.
- Robust connection management: persistent connection per light, heartbeats, fast dead-connection detection, automatic reconnection with backoff, recovery after sleep/wake and network changes, IP rediscovery, and a clear per-light status shown in the UI.
- Light control: power on/off, RGB color via color wheel and hex readout, white mode with color temperature (Kelvin) slider and quick presets, and brightness slider. Rapid slider movement is coalesced so the light follows smoothly without a backlog of stale commands.
- Favorite colors: save the current color, apply, delete; up to 12, persisted across restarts.
- Built-in lighting scenes (Foco Profundo, Cyberpunk, Pôr do Sol, Leitura Noturna, Modo Cinema, Floresta Calma) applied with one click.
- Multiple lights: add lights by importing them once from a Tuya IoT Cloud developer project (to obtain device IDs and local keys) or by manual entry; choose the active light or control all lights at once.
- Secrets (local keys, cloud API secret) stored in the macOS Keychain.
- App preferences: launch at login, global shortcut ⌘⇧L to toggle the popover.

Out of scope for this change: Tuya Cloud control fallback, "Follow Night Shift" from the mockup (no public macOS API), music/rhythm modes, device-side scene/animation DPs, custom user-defined scenes, Matter/Bluetooth connections, Windows/Linux builds, and auto-update/notarized distribution.

## Capabilities

### New Capabilities
- `tuya-device-connection`: Local-network link to Tuya lights — protocol negotiation, connection lifecycle, heartbeats, reconnection, IP discovery, command delivery and status reporting.
- `device-management`: Registering lights (cloud import or manual), storing their credentials securely, editing/removing them, and choosing the active light or all lights.
- `light-control`: Power, color mode, RGB color, color temperature and brightness of the selected light(s), and keeping the UI in sync with the light's actual state.
- `color-favorites`: Saving, applying, deleting and persisting favorite colors.
- `lighting-scenes`: Built-in one-click lighting presets.
- `menubar-app`: Menu bar presence, popover window behavior, global shortcut, launch at login and app lifecycle.

### Modified Capabilities
<!-- None: the project has no existing specs. -->

## Impact

- Greenfield project: new Xcode app project (Swift 6, SwiftUI + AppKit, macOS 14+) plus a local Swift package for the Tuya protocol, in this repository.
- Dependencies are Apple system frameworks (Network, CryptoKit, CommonCrypto, Security/Keychain, ServiceManagement, Carbon hot keys, URLSession); the only third-party package is a test clock (`swift-clocks`) used in tests.
- Requires the Mac and the lights on the same LAN, and (for cloud import) a free Tuya IoT Platform developer project linked to the user's Positivo/Smart Life account.
- The app needs macOS Local Network permission.
