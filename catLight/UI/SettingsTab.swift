import SwiftUI
import TuyaLocal

/// "Ajustes" tab: active light, light list, device actions, launch at login, version and quit.
struct SettingsTab: View {
    var model: AppModel
    var route: Binding<DeviceRoute?>
    @Environment(\.appActions) private var actions
    @State private var loginEnabled = false

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Controlador & Hardware").padding(.horizontal, 4)
            VStack(spacing: 12) {
                HStack {
                    Text("Luz Ativa").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Picker("Luz Ativa", selection: selectionBinding) {
                        ForEach(model.lights) { Text($0.name).tag(LightSelection.light($0.id)) }
                        if model.lights.count > 1 { Text("Todas as luzes (\(model.lights.count))").tag(LightSelection.all) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 185)
                }
                Divider().overlay(Color.white.opacity(0.10))
                lightList
                HStack(spacing: 6) {
                    Button("Adicionar") { route.wrappedValue = .addManual }
                    Button("Importar") { route.wrappedValue = .importCloud }
                    Button("Atualizar chaves") { route.wrappedValue = .refreshKeys }
                }
                .buttonStyle(PillButtonStyle())
                Divider().overlay(Color.white.opacity(0.10))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Iniciar com o macOS").font(.system(size: 12.5, weight: .medium))
                        Text("Manter ícone na barra superior").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    MacSwitch(
                        isOn: Binding(
                            get: { loginEnabled },
                            set: { on in
                                actions.setLaunchAtLogin(on)
                                loginEnabled = actions.launchAtLoginEnabled()
                                model.setLaunchAtLogin(loginEnabled)
                            }),
                        label: "Iniciar com o macOS")
                }
            }
            .padding(12)
            .groupCard()
            HStack {
                Text("catLight v\(version) (macOS)")
                Spacer()
                Text("Atalho: ⌘ ⇧ L")
            }
            .font(.system(size: 11)).foregroundStyle(Theme.gray).padding(.horizontal, 4)
            Button("Sair") { actions.quit() }
                .buttonStyle(PillButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear { loginEnabled = actions.launchAtLoginEnabled() }
    }

    private var selectionBinding: Binding<LightSelection> {
        Binding(get: { model.selection ?? .all }, set: { model.select($0) })
    }

    private var lightList: some View {
        VStack(spacing: 8) {
            ForEach(model.lights) { light in
                let status = model.statuses[light.id] ?? .idle
                HStack(spacing: 8) {
                    Circle().fill(ConnectionText.dotColor(status)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(light.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(ConnectionText.short(status, now: ctx.date)).font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button {
                        route.wrappedValue = .edit(light.id)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help("Editar \(light.name)")
                    .accessibilityLabel("Editar \(light.name)")
                }
            }
        }
    }
}
