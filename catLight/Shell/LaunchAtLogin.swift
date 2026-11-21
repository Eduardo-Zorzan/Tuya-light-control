import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (visible in System Settings → General → Login Items).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // e.g. not allowed yet (needs the user's approval in Login Items); the toggle reflects the real status.
        }
        return isEnabled
    }
}
