import SwiftUI
import TuyaLocal

/// Device chip, power switch, cat-bulb emblem with halo, title and connection notices.
struct HeaderView: View {
    var model: AppModel

    var body: some View {
        let state = model.displayState
        let status = model.headerStatus
        let lit = model.indicatorColor.map(Theme.color) ?? Theme.gray
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(ConnectionText.dotColor(status, powered: state.power)).frame(width: 6, height: 6)
                    Text(model.headerTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().stroke(Color.white.opacity(0.05), lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.headerTitle), \(ConnectionText.short(status))")

                Spacer()
                HStack(spacing: 8) {
                    Text(state.power ? "Ligada" : "Desligada")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.power ? Color(white: 0.83) : Theme.gray)
                    MacSwitch(isOn: Binding(get: { state.power }, set: { model.setPower($0) }), label: "Energia da luz")
                }
            }
            CatBulbEmblem(
                tint: lit,
                haloOpacity: state.power && status.isConnected ? 0.25 + Double(state.brightnessPercent) / 100 * 0.55 : 0
            )
            .padding(.vertical, 6)
            Text("catLight").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
            notices(status: status)
        }
    }

    @ViewBuilder
    private func notices(status: ConnectionStatus) -> some View {
        if !status.isConnected, status != .idle {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(ConnectionText.short(status, now: context.date)) — último estado conhecido")
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(noticeColor(status))
            }
        }
        if model.hasUnappliedChange {
            Label("Mudança não aplicada", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.amber)
        }
    }

    private func noticeColor(_ status: ConnectionStatus) -> Color {
        if case .error = status { return Theme.red }
        return Theme.amber
    }
}
