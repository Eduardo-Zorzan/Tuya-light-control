import SwiftUI
import TuyaLocal

/// "Luz" tab: color/white mode, wheel with hex readout and favorites, brightness and temperature sliders.
struct LuzTab: View {
    var model: AppModel

    @State private var brightnessDrag: Double?
    @State private var kelvinDrag: Double?
    @State private var hexText = ""
    @State private var hexInvalid = false
    @State private var saveLabel = "+ Salvar"
    @State private var saveReset: Task<Void, Never>?
    @State private var brightnessThrottle: IntentThrottle<Int>?
    @State private var kelvinThrottle: IntentThrottle<Int>?
    @State private var wheelThrottle: IntentThrottle<[Int]>?
    @FocusState private var hexFocused: Bool

    private var state: LightState { model.displayState }
    private var accent: Color { Theme.color(model.indicatorColorOrLast) }

    var body: some View {
        VStack(spacing: 12) {
            modeRow
            wheelCard
            slidersCard
        }
        .opacity(model.isDisplayStateCurrent ? 1 : 0.85)
        .onAppear {
            hexText = model.currentHex
            brightnessThrottle = IntentThrottle { model.setBrightness(percent: $0) }
            kelvinThrottle = IntentThrottle { model.setTemperature(kelvin: $0) }
            wheelThrottle = IntentThrottle { model.setColor(hue: $0[0], saturation: $0[1]) }
        }
        .onChange(of: model.currentHex) { _, new in if !hexFocused { hexText = new } }
    }

    // MARK: Mode

    private var modeRow: some View {
        HStack {
            SectionTitle(text: "Espectro de Cor")
            Spacer()
            HStack(spacing: 0) {
                modeButton("Cor RGB", .color)
                modeButton("Branco CCT", .white)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .padding(.horizontal, 4)
    }

    private func modeButton(_ title: String, _ mode: LightMode) -> some View {
        let active = state.mode == mode
        return Button(title) { model.setMode(mode) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.white : Theme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.white.opacity(0.15) : .clear))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Wheel card

    private var wheelCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ColorWheel(
                hue: state.hsv.h, saturation: state.hsv.s, cursorColor: accent, dimmed: state.mode == .white,
                onPick: { h, s in wheelThrottle?.submit([h, s]) },
                onEditingChanged: { editing in
                    if editing {
                        model.beginEditing(.colorWheel)
                    } else {
                        wheelThrottle?.flush()
                        model.endEditing(.colorWheel)
                    }
                })
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cor Selecionada").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).minimumScaleFactor(
                        0.8)
                    Spacer()
                    Button(action: save) {
                        Text(saveLabel).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.sky)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sky.opacity(0.15)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.sky.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Salvar cor atual nas favoritas")
                }
                hexField
                FavoritesView(model: model)
                Spacer(minLength: 0)
            }
            .frame(height: 148)
        }
        .padding(12)
        .groupCard()
    }

    private var hexField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(Theme.color(RGBColor(hex: model.currentHex) ?? RGBColor(r: 255, g: 255, b: 255)))
                    .frame(width: 16, height: 16).overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .focused($hexFocused)
                    .onSubmit(commitHex)
                    .onChange(of: hexFocused) { _, focused in
                        if !focused { hexText = model.currentHex; hexInvalid = false }
                    }
                    .accessibilityLabel("Código hexadecimal da cor")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hexInvalid ? Theme.red : Color.white.opacity(0.10), lineWidth: 1))
            if hexInvalid {
                Text("Hex inválido").font(.system(size: 10)).foregroundStyle(Theme.red)
            }
        }
    }

    private func commitHex() {
        if model.setColor(hex: hexText) {
            hexInvalid = false
            hexText = model.currentHex
        } else {
            hexInvalid = true  // the light is left unchanged
        }
    }

    private func save() {
        let result = model.saveFavorite()
        saveLabel = result == .added ? "✓ Salva!" : "✓ Já salva"
        saveReset?.cancel()
        saveReset = Task {
            try? await Task.sleep(for: .milliseconds(1100))
            if !Task.isCancelled { saveLabel = "+ Salvar" }
        }
    }

    // MARK: Sliders card

    private var slidersCard: some View {
        VStack(spacing: 14) {
            brightnessRow
            Divider().overlay(Color.white.opacity(0.10))
            temperatureRow
        }
        .padding(12)
        .groupCard()
    }

    private var brightnessRow: some View {
        let percent = brightnessDrag.map { max(1, Int(($0 * 100).rounded())) } ?? state.brightnessPercent
        return VStack(spacing: 4) {
            HStack {
                Label("Claridade", systemImage: "sun.max").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.88))
                Spacer()
                Text(verbatim: "\(percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            HStack(spacing: 10) {
                Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(Theme.gray)
                MacSlider(
                    value: brightnessDrag ?? Double(state.brightnessPercent) / 100,
                    fill: state.power ? accent : Color(white: 0.32), step: 0.05, label: "Claridade",
                    onChange: { v in
                        brightnessDrag = v
                        brightnessThrottle?.submit(max(1, Int((v * 100).rounded())))
                    },
                    onEditingChanged: { editing in
                        if editing {
                            model.beginEditing(.brightness)
                        } else {
                            brightnessThrottle?.flush()
                            model.endEditing(.brightness)
                            brightnessDrag = nil
                        }
                    })
                Image(systemName: "sun.max").font(.system(size: 13)).foregroundStyle(Color(white: 0.85))
            }
        }
    }

    private var temperatureRow: some View {
        let range = model.kelvinRange
        let kelvin = kelvinDrag.map { Self.kelvin(forRatio: $0, in: range) } ?? model.currentKelvin
        let ratio = kelvinDrag ?? Double(kelvin - range.lowerBound) / Double(max(1, range.upperBound - range.lowerBound))
        return VStack(spacing: 4) {
            HStack {
                Label("Tom de Calor", systemImage: "thermometer.medium").font(.system(size: 12, weight: .medium)).foregroundStyle(
                    Color(white: 0.88))
                Spacer()
                Text(verbatim: "\(kelvin)K • \(ConnectionText.kelvinLabel(kelvin))")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Color(red: 1, green: 0.83, blue: 0.4))
            }
            HStack(spacing: 10) {
                Text("Quente").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.amber.opacity(0.9))
                MacSlider(
                    value: ratio, fill: .clear, gradient: Self.kelvinGradient, step: 0.05, label: "Tom de calor",
                    onChange: { v in
                        kelvinDrag = v
                        kelvinThrottle?.submit(Self.kelvin(forRatio: v, in: range))
                    },
                    onEditingChanged: { editing in
                        if editing {
                            model.beginEditing(.temperature)
                        } else {
                            kelvinThrottle?.flush()
                            model.endEditing(.temperature)
                            kelvinDrag = nil
                        }
                    })
                Text("Frio").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.sky.opacity(0.9))
            }
            HStack(spacing: 6) {
                ForEach(TemperaturePreset.allCases, id: \.self) { preset in
                    Button {
                        model.setPreset(preset)
                    } label: {
                        Text(verbatim: "\(preset.kelvin)K \(preset.title)")
                            .font(.system(size: 11)).foregroundStyle(presetColor(preset))
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private func presetColor(_ p: TemperaturePreset) -> Color {
        switch p {
        case .vela: return Color(red: 1, green: 0.9, blue: 0.6)
        case .leitura: return Color(white: 0.88)
        case .foco: return Color(red: 0.75, green: 0.9, blue: 1)
        }
    }

    static let kelvinGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 1, green: 0.549, blue: 0.141), location: 0),
            .init(color: Color(red: 1, green: 0.773, blue: 0.471), location: 0.35),
            .init(color: Color(red: 1, green: 0.961, blue: 0.91), location: 0.6),
            .init(color: Color(red: 0.796, green: 0.886, blue: 1), location: 1),
        ], startPoint: .leading, endPoint: .trailing)

    /// Slider ratio → Kelvin in 50 K steps, inside the light's range.
    static func kelvin(forRatio ratio: Double, in range: ClosedRange<Int>) -> Int {
        let raw = Double(range.lowerBound) + ratio * Double(range.upperBound - range.lowerBound)
        let stepped = Int((raw / 50).rounded()) * 50
        return max(range.lowerBound, min(range.upperBound, stepped))
    }
}

extension AppModel {
    /// Indicator color, falling back to a neutral when gray (so sliders/cursor still have a hue to show).
    var indicatorColorOrLast: TuyaLocal.RGBColor {
        indicatorColor ?? HSV(h: displayState.hsv.h, s: displayState.hsv.s, v: 1000).rgb
    }
}
