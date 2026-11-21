import AppKit
import Network
import TuyaLocal

/// Wake-from-sleep and network-change triggers: each drops stale connections and reconnects immediately.
@MainActor
final class SystemEvents {
    private let monitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var lastSignature: String?

    func start(model: AppModel) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Log.info(.connection, "trigger: wake from sleep")
            MainActor.assumeIsolated { model.systemDidWake() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.availableInterfaces.map(\.name).sorted())"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastSignature = signature }
                guard let last = self.lastSignature, last != signature else { return }  // ignore the initial report
                Log.info(.connection, "trigger: network path changed")
                model.networkDidChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "catlight.path"))
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
