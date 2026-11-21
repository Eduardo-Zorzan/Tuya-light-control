import AppKit
import SwiftUI

/// Things the views ask the app shell to do.
@MainActor
struct AppActions: Sendable {
    var quit: @MainActor () -> Void = {}
    var launchAtLoginEnabled: @MainActor () -> Bool = { false }
    var setLaunchAtLogin: @MainActor (Bool) -> Void = { _ in }
    var openLocalNetworkSettings: @MainActor () -> Void = {}
    var closePopover: @MainActor () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey { static let defaultValue = MainActor.assumeIsolated { AppActions() } }

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

enum DeviceRoute: Equatable {
    case addManual
    case edit(String)
    case importCloud
    case refreshKeys
}

/// Shared button style for the secondary actions.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? Theme.red : prominent ? .white : Color(white: 0.9))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: prominent ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(
                    prominent ? Theme.tabActive : Color.white.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
