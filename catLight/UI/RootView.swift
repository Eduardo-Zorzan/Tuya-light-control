import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case luz, cenas, ajustes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .luz: return "Luz"
        case .cenas: return "Cenas"
        case .ajustes: return "Ajustes"
        }
    }
    var symbol: String {
        switch self {
        case .luz: return "sun.max"
        case .cenas: return "drop"
        case .ajustes: return "slider.horizontal.3"
        }
    }
}

/// Popover content: first-run setup, permission notice, device forms, or header + tabs.
struct RootView: View {
    var model: AppModel
    @State private var tab: PopoverTab
    @State private var route: DeviceRoute?
    @Environment(\.appActions) private var actions

    init(model: AppModel, initialTab: PopoverTab = .luz, initialRoute: DeviceRoute? = nil) {
        self.model = model
        _tab = State(initialValue: initialTab)
        _route = State(initialValue: initialRoute)
    }

    var body: some View {
        content
            .padding(16)
            .frame(width: Theme.width)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .onExitCommand { if route != nil { route = nil } else { actions.closePopover() } }
    }

    @ViewBuilder
    private var content: some View {
        if let route {
            routeView(route)
        } else if !model.hasLights {
            SetupView(route: $route)
        } else if model.localNetworkDenied {
            LocalNetworkDeniedView()
        } else {
            VStack(spacing: 14) {
                HeaderView(model: model)
                TabBar(selection: $tab, title: \.title, symbol: \.symbol)
                switch tab {
                case .luz: LuzTab(model: model)
                case .cenas: ScenesTab(model: model)
                case .ajustes: SettingsTab(model: model, route: $route)
                }
            }
        }
    }

    @ViewBuilder
    private func routeView(_ route: DeviceRoute) -> some View {
        let close = { self.route = nil }
        switch route {
        case .addManual: LightFormView(model: model, editingID: nil, onDone: close)
        case .edit(let id): LightFormView(model: model, editingID: id, onDone: close)
        case .importCloud: CloudImportView(model: model, refresh: false, onDone: close)
        case .refreshKeys: CloudImportView(model: model, refresh: true, onDone: close)
        }
    }
}
