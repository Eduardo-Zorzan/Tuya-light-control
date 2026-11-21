import AppKit
import Carbon.HIToolbox
import SwiftUI
import TuyaLocal

/// Menu bar agent (no Dock icon, `LSUIElement = YES`). All UI lives in the status item's popover.
@main
struct CatLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }  // no windows
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit-test host launches this app too: keep it inert so tests never touch real lights or the Keychain.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        controller = AppController()
        controller?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        Task {
            await controller.shutdown()  // closes sockets; never sends a command, so the lights keep their state
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Wires the pieces together: persistence, connections, discovery, UI shell, shortcut and system triggers.
@MainActor
final class AppController {
    let model: AppModel
    private let manager: DeviceManager
    private let discovery = TuyaDiscovery()
    private let systemEvents = SystemEvents()
    private var statusItem: StatusItemController?
    private var hotKey: HotKey?
    private var discoveryTask: Task<Void, Never>?

    init() {
        let store =
            (try? ConfigStore.standard())
            ?? ConfigStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("catlight-config.json"))
        manager = DeviceManager()
        let registry = DeviceRegistry(store: store, secrets: KeychainStore(), manager: manager)
        model = AppModel(registry: registry, manager: manager)
        model.onSetupCompleted = {
            // Default on after first setup.
            if LaunchAtLogin.set(true) { Log.info(.ui, "launch at login enabled after first setup") }
        }
    }

    func start() {
        var actions = AppActions()
        actions.quit = { NSApp.terminate(nil) }
        actions.launchAtLoginEnabled = { LaunchAtLogin.isEnabled }
        actions.setLaunchAtLogin = { LaunchAtLogin.set($0) }
        actions.openLocalNetworkSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        }
        statusItem = StatusItemController(model: model, actions: actions)
        hotKey = HotKey(keyCode: kVK_ANSI_L, modifiers: cmdKey | shiftKey) { [weak self] in self?.statusItem?.toggle() }
        if hotKey == nil { Log.error(.ui, "global shortcut could not be registered") }

        let status = discovery.start()
        model.setDiscoveryUnavailable(status.isUnavailable)
        discoveryTask = Task { [model, discovery] in
            for await device in discovery.devices { await model.discovered(device) }
        }
        systemEvents.start(model: model)
        Task { await model.start() }
    }

    func shutdown() async {
        discoveryTask?.cancel()
        discovery.stop()
        systemEvents.stop()
        hotKey?.unregister()
        await model.shutdown()
    }
}
