import Foundation

/// Builds datapoint patches from user intents. Every change made while the light is off also
/// turns it on; color changes send `work_mode` and the color in the same frame (no flash).
public struct LightIntents: Sendable {
    public let codec: LightCodec
    public init(codec: LightCodec) { self.codec = codec }

    private func turnOnIfNeeded(_ patch: inout DPMap, _ state: LightState) {
        if !state.power { patch[codec.switchDP] = .bool(true) }
    }

    public func power(_ on: Bool) -> DPMap {
        [codec.switchDP: .bool(on)]
    }

    /// Picks a hue/saturation in color mode, keeping the current color brightness.
    public func color(hue: Int, saturation: Int, state: LightState) -> DPMap {
        color(HSV(h: hue, s: saturation, v: state.hsv.v), state: state)
    }

    public func color(_ hsv: HSV, state: LightState) -> DPMap {
        var patch: DPMap = [
            codec.modeDP: .string("colour"),
            codec.colourDP: .string(codec.encodeColour(hsv)),
        ]
        turnOnIfNeeded(&patch, state)
        return patch
    }

    /// Brightness 1–100% for the *current* mode: color `v` in color mode, white brightness in white mode.
    public func brightness(percent: Int, state: LightState) -> DPMap {
        let p = max(1, min(100, percent))
        var patch: DPMap
        switch state.mode {
        case .color:
            var hsv = state.hsv
            hsv.v = p * 10
            patch = [codec.colourDP: .string(codec.encodeColour(hsv))]
        case .white:
            patch = [codec.brightDP: .int(codec.dp(whiteBrightness: p * 10))]
        }
        turnOnIfNeeded(&patch, state)
        return patch
    }

    /// White mode at `kelvin` (clamped to the light's range); using the temperature slider switches to white.
    public func temperature(kelvin: Int, state: LightState) -> DPMap {
        var patch: DPMap = [
            codec.modeDP: .string("white"),
            codec.tempDP: .int(codec.dp(temp: codec.temp(kelvin: kelvin))),
        ]
        turnOnIfNeeded(&patch, state)
        return patch
    }

    /// Switches between color and white restoring the last values used in that mode.
    public func mode(_ mode: LightMode, state: LightState) -> DPMap {
        var patch: DPMap
        switch mode {
        case .color:
            patch = [
                codec.modeDP: .string("colour"),
                codec.colourDP: .string(codec.encodeColour(state.hsv)),
            ]
        case .white:
            patch = [
                codec.modeDP: .string("white"),
                codec.tempDP: .int(codec.dp(temp: state.temp)),
                codec.brightDP: .int(codec.dp(whiteBrightness: state.whiteBrightness)),
            ]
        }
        turnOnIfNeeded(&patch, state)
        return patch
    }

    /// A built-in scene as one patch: mode, color or temperature, brightness, and power on.
    public func scene(_ scene: LightScene, state _: LightState) -> DPMap {
        var patch: DPMap = [codec.switchDP: .bool(true)]
        switch scene.setting {
        case .white(let kelvin, let percent):
            patch[codec.modeDP] = .string("white")
            patch[codec.tempDP] = .int(codec.dp(temp: codec.temp(kelvin: kelvin)))
            patch[codec.brightDP] = .int(codec.dp(whiteBrightness: max(1, min(100, percent)) * 10))
        case .color(let hue, let saturationPercent, let brightnessPercent):
            patch[codec.modeDP] = .string("colour")
            let hsv = HSV(h: hue, s: saturationPercent * 10, v: max(1, min(100, brightnessPercent)) * 10)
            patch[codec.colourDP] = .string(codec.encodeColour(hsv))
        }
        return patch
    }
}

/// Quick temperature presets (Kelvin) shown under the slider.
public enum TemperaturePreset: CaseIterable, Sendable {
    case vela, leitura, foco
    public var kelvin: Int {
        switch self {
        case .vela: return 2400
        case .leitura: return 4200
        case .foco: return 6200
        }
    }
    public var title: String {
        switch self {
        case .vela: return "Vela"
        case .leitura: return "Leitura"
        case .foco: return "Foco"
        }
    }
}

public struct LightScene: Sendable, Equatable, Identifiable {
    public enum Setting: Sendable, Equatable {
        case white(kelvin: Int, brightnessPercent: Int)
        case color(hue: Int, saturationPercent: Int, brightnessPercent: Int)
    }
    public let id: String
    public let name: String
    public let summary: String
    /// Emoji shown on the scene card.
    public let icon: String
    public let setting: Setting

    /// The six built-in scenes of the Cenas tab (captions and icons from the reference mockup).
    public static let all: [LightScene] = [
        LightScene(
            id: "foco-profundo", name: "Foco Profundo", summary: "Branco Frio • 100%", icon: "⚡",
            setting: .white(kelvin: 6200, brightnessPercent: 100)),
        LightScene(
            id: "cyberpunk", name: "Cyberpunk", summary: "Magenta RGB • 90%", icon: "🌌",
            setting: .color(hue: 295, saturationPercent: 92, brightnessPercent: 90)),
        LightScene(
            id: "por-do-sol", name: "Pôr do Sol", summary: "Âmbar Quente • 70%", icon: "🌅",
            setting: .color(hue: 26, saturationPercent: 95, brightnessPercent: 70)),
        LightScene(
            id: "leitura-noturna", name: "Leitura Noturna", summary: "2500K Suave • 45%", icon: "🕯️",
            setting: .white(kelvin: 2500, brightnessPercent: 45)),
        LightScene(
            id: "modo-cinema", name: "Modo Cinema", summary: "Azul Profundo • 30%", icon: "🎬",
            setting: .color(hue: 228, saturationPercent: 94, brightnessPercent: 30)),
        LightScene(
            id: "floresta-calma", name: "Floresta Calma", summary: "Verde Suave • 60%", icon: "🌿",
            setting: .color(hue: 145, saturationPercent: 82, brightnessPercent: 60)),
    ]
}
