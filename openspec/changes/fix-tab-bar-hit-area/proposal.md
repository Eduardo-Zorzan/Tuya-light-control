# Proposal

## Why

In the popover's tab bar (Luz / Cenas / Ajustes), clicking an inactive tab only works when the pointer is on the icon or label. Clicks on the rest of the tab's area do nothing, so switching tabs feels broken. The screen recording from 2026-11-21 shows several clicks on empty tab space that do nothing before the user clicks the label. The Cor RGB / Branco CCT mode toggle on the Luz tab has the same problem.

## What Changes

- Make every segment of the popover tab bar respond to clicks anywhere inside its visible bounds (the full pill area, including padding), whether it is active or not.
- Apply the same fix to the Cor RGB / Branco CCT mode toggle on the Luz tab. Its padding is currently outside the button, and its inactive background is transparent, so only the text is clickable.
- Add an explicit UI requirement: each segment of a segmented control must be clickable across its whole visible area. This stops the bug from coming back.
- No visual change: layout, colors, sizes and accessibility traits stay the same.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `menubar-app`: adds a requirement that each segment of the popover's segmented controls (tab bar and Luz mode toggle) responds to clicks across its whole visible area. This capability is introduced by the in-progress change `add-macos-menubar-light-controller` and is not yet in `openspec/specs/`, so the delta is written as an ADDED requirement.

## Impact

- Code: `catLight/UI/Controls.swift` (`TabBar`) and `catLight/UI/LuzTab.swift` (`modeButton`).
- No API, persistence, dependency or `TuyaLocal` package changes.
- Out of scope: other `.plain` buttons (scene cards, temperature presets, favorites, the save button and the edit pencil). They already have a non-transparent background over their whole area or are intentionally icon-sized.
