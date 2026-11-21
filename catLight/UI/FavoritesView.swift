import SwiftUI
import TuyaLocal

/// Favorite colors grid: apply on click, delete control revealed on hover or keyboard focus.
struct FavoritesView: View {
    var model: AppModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Favoritas").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(model.favorites.countLabel).font(.system(size: 10)).foregroundStyle(Theme.gray)
            }
            if model.favorites.isEmpty {
                Text("Nenhuma favorita salva")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(model.favorites.colors, id: \.self) { hex in
                            FavoriteSwatch(hex: hex, apply: { model.applyFavorite(hex) }, delete: { model.deleteFavorite(hex) })
                        }
                    }
                    .padding(.top, 3)
                }
                .frame(maxHeight: 68)
            }
        }
    }
}

private struct FavoriteSwatch: View {
    let hex: String
    let apply: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let color = RGBColor(hex: hex).map(Theme.color) ?? .gray
        ZStack(alignment: .topTrailing) {
            Button(action: apply) {
                Circle().fill(color).frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .scaleEffect(hovering ? 1.1 : 1)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .help("Aplicar \(hex)")
            .accessibilityLabel("Aplicar \(hex)")

            Button(action: delete) {
                Text("×").font(.system(size: 9)).foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color(white: 0.1).opacity(0.95)))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .opacity(hovering || focused ? 1 : 0)
            .scaleEffect(hovering || focused ? 1 : 0.75)
            .help("Excluir \(hex)")
            .accessibilityLabel("Excluir \(hex)")
            .offset(x: 3, y: -3)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering || focused)
    }
}
