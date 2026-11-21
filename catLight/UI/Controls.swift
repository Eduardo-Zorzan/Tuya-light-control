import SwiftUI

/// macOS-style switch (38×22, green when on).
struct MacSwitch: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.green : Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(0.36))
                Circle().fill(.white).frame(width: 18, height: 18).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1).padding(2)
            }
            .frame(width: 38, height: 22)
            .animation(.snappy(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "ligado" : "desligado")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Slider with a 7 pt track, colored fill and an 18 pt thumb. Supports drag and keyboard arrows.
struct MacSlider: View {
    /// 0...1
    var value: Double
    var fill: Color
    /// Optional track style (e.g. the Kelvin gradient); the fill is hidden when set.
    var gradient: LinearGradient?
    var step: Double = 0.01
    var label: String
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = max(0, min(1, value)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 7)
                if let gradient {
                    Capsule().fill(gradient).frame(height: 7)
                } else {
                    Capsule().fill(fill).frame(width: thumbX, height: 7)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        onChange(max(0, min(1, drag.location.x / max(1, width))))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-step) }
        .onKeyPress(.rightArrow) { nudge(step) }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) por cento")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = nudge(step)
            case .decrement: _ = nudge(-step)
            @unknown default: break
            }
        }
    }

    private func nudge(_ delta: Double) -> KeyPress.Result {
        onEditingChanged(true)
        onChange(max(0, min(1, value + delta)))
        onEditingChanged(false)
        return .handled
    }
}

/// Segmented tab bar (Luz / Cenas / Ajustes) with the mockup's #235284 active pill.
struct TabBar<Tab: Hashable & CaseIterable & Identifiable>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    var title: (Tab) -> String
    var symbol: (Tab) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(tab)).font(.system(size: 12, weight: .medium))
                        Text(title(tab)).font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(active ? Color.white : Theme.secondaryText)
                    .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.tabActive : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// Leading-edge throttle with a trailing flush: smooth slider drags without a command backlog.
@MainActor
final class IntentThrottle<Value> {
    private let interval: Duration
    private let action: (Value) -> Void
    private var lastFire: ContinuousClock.Instant?
    private var pending: Value?
    private var trailing: Task<Void, Never>?

    init(interval: Duration = .milliseconds(50), action: @escaping (Value) -> Void) {
        self.interval = interval
        self.action = action
    }

    func submit(_ value: Value) {
        let now = ContinuousClock.now
        if let last = lastFire, now - last < interval {
            pending = value
            if trailing == nil {
                let wait = interval - (now - last)
                trailing = Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled else { return }
                    self?.flush()
                }
            }
        } else {
            fire(value)
        }
    }

    /// Sends the pending value now (called when the drag ends so the light settles on the final value).
    func flush() {
        trailing?.cancel()
        trailing = nil
        if let value = pending {
            pending = nil
            fire(value)
        }
    }

    private func fire(_ value: Value) {
        lastFire = ContinuousClock.now
        action(value)
    }
}
