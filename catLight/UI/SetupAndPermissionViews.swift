import SwiftUI

/// First run (no lights registered): import from the cloud or add by hand.
struct SetupView: View {
    var route: Binding<DeviceRoute?>

    var body: some View {
        VStack(spacing: 14) {
            CatBulbEmblem(tint: Theme.sky, haloOpacity: 0.45)
            Text("Bem-vindo ao catLight").font(.system(size: 15, weight: .semibold))
            Text("Adicione suas luzes Tuya para controlá-las direto pela rede local.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Button("Importar do Tuya IoT") { route.wrappedValue = .importCloud }.buttonStyle(PillButtonStyle(prominent: true))
                Button("Adicionar manualmente") { route.wrappedValue = .addManual }.buttonStyle(PillButtonStyle()).frame(
                    maxWidth: .infinity)
            }
            Text("A importação busca o ID e a chave local de cada luz uma única vez; o controle do dia a dia não usa a nuvem.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }
}

/// Shown when macOS denied Local Network access (the lights cannot be reached without it).
struct LocalNetworkDeniedView: View {
    @Environment(\.appActions) private var actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash").font(.system(size: 34)).foregroundStyle(Theme.amber)
            Text("Permissão de Rede Local necessária").font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
            Text(
                "O macOS bloqueou o acesso do catLight à rede local, então ele não consegue falar com as luzes. Ative o catLight em Ajustes do Sistema → Privacidade e Segurança → Rede Local."
            )
            .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true)
            Button("Abrir Ajustes do Sistema") { actions.openLocalNetworkSettings() }.buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(.vertical, 8)
    }
}
