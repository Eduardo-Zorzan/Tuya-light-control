import Observation
import SwiftUI
import TuyaLocal

@MainActor
@Observable
final class CloudImportModel {
    enum Phase: Equatable {
        case form
        case loading
        case choose([CloudDevice])
        case failed(String)
        case done(String)
    }

    var accessID = ""
    var accessSecret = ""
    var region: TuyaCloudRegion = .westernAmerica
    var rememberSecret = true
    var selected: Set<String> = []
    private(set) var phase: Phase = .form

    /// Builds the cloud client; injectable so tests can use a mocked session.
    @ObservationIgnored var makeClient: (CloudCredentials) -> TuyaCloudClient = { TuyaCloudClient(credentials: $0) }

    func prefill(from saved: (accessID: String, region: TuyaCloudRegion, secret: String?)?) {
        guard let saved else { return }
        accessID = saved.accessID
        region = saved.region
        accessSecret = saved.secret ?? ""
    }

    var canSubmit: Bool { !accessID.trimmed.isEmpty && !accessSecret.trimmed.isEmpty }

    private var credentials: CloudCredentials {
        CloudCredentials(accessID: accessID.trimmed, accessSecret: accessSecret.trimmed, region: region)
    }

    func fetch() async {
        phase = .loading
        do {
            let devices = try await makeClient(credentials).fetchDevices()
            let lights = devices.filter(\.isLight)
            let shown = lights.isEmpty ? devices : lights
            selected = Set(shown.filter { !$0.localKey.isEmpty }.map(\.id))
            phase = .choose(shown)
        } catch {
            // Show the error returned by Tuya as is; nothing is added.
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func importSelected(into model: AppModel, devices: [CloudDevice]) async {
        let picked = devices.filter { selected.contains($0.id) && !$0.localKey.isEmpty }
        do {
            try await model.importLights(picked)
            model.rememberCloud(accessID: accessID.trimmed, region: region, secret: rememberSecret ? accessSecret.trimmed : nil)
            phase = .done("\(picked.count) luz(es) adicionada(s).")
        } catch {
            phase = .failed("Não foi possível adicionar: \(error.localizedDescription)")
        }
    }

    func refreshKeys(into model: AppModel) async {
        phase = .loading
        do {
            let n = try await model.refreshKeys(using: makeClient(credentials))
            model.rememberCloud(accessID: accessID.trimmed, region: region, secret: rememberSecret ? accessSecret.trimmed : nil)
            phase = .done("\(n) chave(s) atualizada(s).")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func backToForm() { phase = .form }
}

/// Import lights (or refresh their local keys) from a Tuya IoT Platform project.
struct CloudImportView: View {
    var model: AppModel
    var refresh: Bool
    var onDone: () -> Void
    @State private var vm = CloudImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: refresh ? "Atualizar chaves" : "Importar do Tuya IoT")
            switch vm.phase {
            case .form: form
            case .loading: ProgressView().frame(maxWidth: .infinity).padding(24)
            case .choose(let devices): chooser(devices)
            case .failed(let message): failure(message)
            case .done(let message): done(message)
            }
        }
        .onAppear { vm.prefill(from: model.savedCloud) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Access ID", text: $vm.accessID).textFieldStyle(.roundedBorder)
                SecureField("Access Secret", text: $vm.accessSecret).textFieldStyle(.roundedBorder)
                Picker("Região", selection: $vm.region) {
                    ForEach(TuyaCloudRegion.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Lembrar o Access Secret (Keychain)", isOn: $vm.rememberSecret).font(.system(size: 11.5))
            }
            .padding(12).groupCard()
            Text(
                "Crie um projeto gratuito em iot.tuya.com, vincule a conta do app (Smart Life ou Positivo Casa Inteligente) em “Link App Account” e cole o Access ID e o Access Secret. A nuvem só é usada para esta importação."
            )
            .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar", action: onDone).buttonStyle(PillButtonStyle())
                Button(refresh ? "Atualizar" : "Buscar luzes") {
                    Task { refresh ? await vm.refreshKeys(into: model) : await vm.fetch() }
                }
                .buttonStyle(PillButtonStyle(prominent: true)).fixedSize().disabled(!vm.canSubmit)
            }
        }
    }

    private func chooser(_ devices: [CloudDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if devices.isEmpty {
                Text("Nenhum dispositivo encontrado nesta conta.").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
            VStack(spacing: 6) {
                ForEach(devices) { d in
                    Toggle(
                        isOn: Binding(
                            get: { vm.selected.contains(d.id) },
                            set: { on in if on { vm.selected.insert(d.id) } else { vm.selected.remove(d.id) } })
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 12.5, weight: .medium))
                            Text(d.localKey.isEmpty ? "sem chave local" : (d.online ? "online" : "offline")).font(.system(size: 10.5))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .disabled(d.localKey.isEmpty)
                }
            }
            .padding(12).groupCard()
            HStack {
                Spacer()
                Button("Cancelar", action: onDone).buttonStyle(PillButtonStyle())
                Button("Adicionar selecionadas") { Task { await vm.importSelected(into: model, devices: devices) } }
                    .buttonStyle(PillButtonStyle(prominent: true)).fixedSize().disabled(vm.selected.isEmpty)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            Text("Se a conta do app Positivo não puder ser vinculada, pareie as luzes no app Smart Life ou informe as chaves manualmente.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar", action: onDone).buttonStyle(PillButtonStyle())
                Button("Tentar de novo") { vm.backToForm() }.buttonStyle(PillButtonStyle(prominent: true)).fixedSize()
            }
        }
    }

    private func done(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 12))
            Button("Concluir", action: onDone).buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}
