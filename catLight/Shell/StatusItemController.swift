import AppKit
import Observation
import SwiftUI
import TuyaLocal

/// Menu bar item (cat-bulb + status dot), the popover it toggles, and the right-click menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let actions: AppActions
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        super.init()
        configurePopover()
        configureButton()
        updateIcon()
        observeModel()
    }

    // MARK: Popover

    private func configurePopover() {
        popover.behavior = .transient  // closes on outside click and when another app is activated
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.animates = true
        popover.delegate = self
        var rootActions = actions
        rootActions.closePopover = { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: RootView(model: model).environment(\.appActions, rootActions))
        host.sizingOptions = [.preferredContentSize]  // the popover follows the content height when tabs change
        popover.contentViewController = host
    }

    var isShown: Bool { popover.isShown }

    func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    func show() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)  // so text fields can take focus
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverWillShow(_ notification: Notification) {
        model.popoverWillShow()  // reconnect lights that are not connected, refresh those that are
    }

    // MARK: Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("catLight")
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Sair", action: #selector(quitSelected), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // keep left click for the popover
    }

    @objc private func quitSelected() { actions.quit() }

    /// Redraws the icon: glyph in the menu bar's label color, dot in the light color (gray when off or offline).
    func updateIcon() {
        guard let button = statusItem.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let glyph: NSColor = isDark ? .white : .black
        let dot = model.indicatorColor.map {
            NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
        }
        button.image = StatusItemImage.make(glyph: glyph, dot: dot)
        button.setAccessibilityValue(model.indicatorColor == nil ? "luz apagada ou offline" : "luz acesa")
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.indicatorColor
            _ = model.displayState
            _ = model.headerStatus
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateIcon()
                self?.observeModel()
            }
        }
    }
}
