import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut via Carbon `RegisterEventHotKey` (needs no Accessibility permission).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// Returns `nil` if the system refused the registration (e.g. the combination is taken).
    init?(keyCode: Int, modifiers: Int, handler: @escaping @MainActor () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4354_4C54), id: id)  // 'CTLT'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return nil }
        ref = hotKeyRef
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
    }
}
