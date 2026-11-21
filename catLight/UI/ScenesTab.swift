import SwiftUI
import TuyaLocal

/// "Cenas" tab: two-column grid of built-in scenes with the active one highlighted.
struct ScenesTab: View {
    var model: AppModel
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Ambientes Pré-Definidos").padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(LightScene.all) { scene in
                    SceneCard(scene: scene, active: model.activeSceneID == scene.id) { model.applyScene(scene) }
                }
            }
        }
    }
}

private struct SceneCard: View {
    let scene: LightScene
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    private var accent: Color {
        switch scene.id {
        case "foco-profundo": return Color(red: 0.22, green: 0.74, blue: 0.97)
        case "cyberpunk": return Color(red: 0.91, green: 0.47, blue: 0.98)
        case "por-do-sol": return Color(red: 0.98, green: 0.57, blue: 0.24)
        case "leitura-noturna": return Color(red: 0.98, green: 0.75, blue: 0.14)
        case "modo-cinema": return Color(red: 0.51, green: 0.55, blue: 0.97)
        default: return Color(red: 0.2, green: 0.83, blue: 0.6)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(scene.icon).font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.2)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.3), lineWidth: 1))
                    .padding(.bottom, 8)
                Text(scene.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(hovering || active ? accent : .white)
                Text(scene.summary).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .groupCard()
            .overlay(
                RoundedRectangle(cornerRadius: 13).stroke(
                    active ? accent : hovering ? accent.opacity(0.5) : .clear, lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(scene.name), \(scene.summary)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
