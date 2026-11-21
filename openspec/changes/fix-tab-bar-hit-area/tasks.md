# Tasks

Root cause: these buttons use `.buttonStyle(.plain)`. With that style, SwiftUI on macOS only counts clicks on the label's non-transparent pixels. The inactive tab's background is `.clear`, so only the SF Symbol and the text register clicks. In `modeButton`, `.padding` and `.background` are applied outside the `Button`, so even the pill's padding is not part of the button.

## 1. Tab bar

- [x] 1.1 In `catLight/UI/Controls.swift` (`TabBar`), add `.contentShape(RoundedRectangle(cornerRadius: 8))` to each segment's label after its `.frame`/`.padding`. Leave the visuals as they are. Verify with `make build`, then in the running app (`make run`) click empty space and the edges of every inactive tab and check that it switches each time.

## 2. Luz mode toggle

- [x] 2.1 In `catLight/UI/LuzTab.swift` (`modeButton`), move the font, padding and background into the `Button`'s `label:` and add `.contentShape(RoundedRectangle(cornerRadius: 6))`. Keep `.buttonStyle(.plain)` and the `.isSelected` trait on the button. Verify in the running app that clicking the padding of the inactive Cor RGB / Branco CCT option switches mode, and that the toggle looks the same as before.

## 3. Checks

- [x] 3.1 Run `make check` (swift-format lint and all tests) and confirm it passes. Then run the `catLightTests` snapshot suite and compare the `luz-*` PNGs with the previous render to confirm there is no visual change.
- [x] 3.2 Repeat each scenario in `specs/menubar-app/spec.md` by hand in the running app, including that clicks in the 4 pt gap between tabs change nothing, and note the result in the commit message.
