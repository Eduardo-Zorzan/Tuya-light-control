import SwiftUI
import TuyaLocal

/// Add or edit a light by hand (name, device ID, local key, optional IP / version / Kelvin range).
struct LightFormView: View {
    var model: AppModel
    var editingID: String?
    var onDone: () -> Void

    @State private var draft = LightDraft()
    @State private var invalid: Set<LightDraft.Field> = []
    @State private var confirmRemove = false
    @State private var errorText: String?

    private var isEditing: Bool { editingID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: isEditing ? "Editar luz" : "Adicionar luz")
            VStack(alignment: .leading, spacing: 8) {
                field("Nome", text: $draft.name, field: .name)
                field("ID do dispositivo", text: $draft.deviceID, field: .deviceID).disabled(isEditing).opacity(isEditing ? 0.6 : 1)
                secureField
                field("Endereço IP (opcional)", text: $draft.ip, field: nil)
                HStack {
                    Text("Protocolo").font(.system(size: 11.5))
                    Spacer()
                    Picker("Protocolo", selection: $draft.version) {
                        Text("Automático").tag(TuyaVersion?.none)
                        ForEach(TuyaVersion.allCases, id: \.self) { Text($0.rawValue).tag(TuyaVersion?.some($0)) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("Faixa de temperatura (K)").font(.system(size: 11.5))
                    Spacer()
                    TextField("min", value: $draft.kelvinMin, format: .number.grouping(.never)).frame(width: 54)
                    Text("–")
                    TextField("max", value: $draft.kelvinMax, format: .number.grouping(.never)).frame(width: 54)
                }
                .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
                if invalid.contains(.kelvinRange) { Text("Faixa inválida").font(.system(size: 10)).foregroundStyle(Theme.red) }
            }
            .padding(12).groupCard()
            if let errorText { Text(errorText).font(.system(size: 11)).foregroundStyle(Theme.red) }
            HStack {
                if isEditing {
                    if confirmRemove {
                        Button("Confirmar remoção") { remove() }.buttonStyle(PillButtonStyle(destructive: true))
                    } else {
                        Button("Remover") { confirmRemove = true }.buttonStyle(PillButtonStyle(destructive: true))
                    }
                }
                Spacer()
                Button("Cancelar", action: onDone).buttonStyle(PillButtonStyle())
                Button("Salvar") { save() }.buttonStyle(PillButtonStyle(prominent: true)).fixedSize()
            }
        }
        .onAppear(perform: load)
    }

    private func field(_ title: String, text: Binding<String>, field: LightDraft.Field?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(field.map(invalid.contains) == true ? Theme.red : .clear, lineWidth: 1.5))
                .accessibilityLabel(title)
        }
    }

    private var secureField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Chave local").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            SecureField(isEditing ? "Deixe em branco para manter a atual" : "16 caracteres", text: $draft.localKey)
                .textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid.contains(.localKey) ? Theme.red : .clear, lineWidth: 1.5))
                .accessibilityLabel("Chave local")
            if invalid.contains(.localKey) {
                Text(draft.localKey.trimmed.isEmpty ? "Obrigatória" : "Deve ter 16 caracteres").font(.system(size: 10)).foregroundStyle(
                    Theme.red)
            }
        }
    }

    private func load() {
        guard let id = editingID, let light = model.lights.first(where: { $0.id == id }) else { return }
        draft = LightDraft(
            name: light.name, deviceID: light.id, localKey: "", ip: light.ip ?? "", version: light.version, kelvinMin: light.kelvinMin,
            kelvinMax: light.kelvinMax, productID: light.productID)
    }

    private func save() {
        Task {
            do {
                if let id = editingID { try await model.updateLight(id: id, with: draft) } else { try await model.addLight(draft) }
                invalid = []
                onDone()
            } catch let e as LightValidationError {
                invalid = e.fields
            } catch {
                errorText = "Não foi possível salvar: \(error.localizedDescription)"
            }
        }
    }

    private func remove() {
        guard let id = editingID else { return }
        Task {
            await model.removeLight(id: id)
            onDone()
        }
    }
}
