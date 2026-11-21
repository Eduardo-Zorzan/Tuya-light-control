import Foundation

public enum LightMode: String, Sendable, Equatable, Codable {
    case color
    case white
}

/// Hue 0–360°, saturation 0–1000, value 0–1000 (Tuya's HSV scale).
public struct HSV: Sendable, Equatable, Codable {
    public var h: Int
    public var s: Int
    public var v: Int

    public init(h: Int, s: Int, v: Int) {
        self.h = max(0, min(360, h))
        self.s = max(0, min(1000, s))
        self.v = max(0, min(1000, v))
    }

    public var rgb: RGBColor {
        let hh = Double(h % 360) / 60.0, ss = Double(s) / 1000.0, vv = Double(v) / 1000.0
        let c = vv * ss
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = vv - c
        let (r, g, b): (Double, Double, Double)
        switch Int(hh) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ d: Double) -> UInt8 { UInt8(max(0, min(255, ((d + m) * 255).rounded()))) }
        return RGBColor(r: byte(r), g: byte(g), b: byte(b))
    }
}

/// 8-bit RGB with hex parsing for the color readout.
public struct RGBColor: Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    /// Parses `#RRGGBB` / `RRGGBB` (case-insensitive). Anything else is rejected.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let n = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((n >> 16) & 0xFF), g: UInt8((n >> 8) & 0xFF), b: UInt8(n & 0xFF))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Hue/saturation/value on Tuya's scale (value keeps the RGB's own brightness).
    public var hsv: HSV {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == rf {
                h = 60 * ((gf - bf) / d).truncatingRemainder(dividingBy: 6)
            } else if mx == gf {
                h = 60 * ((bf - rf) / d + 2)
            } else {
                h = 60 * ((rf - gf) / d + 4)
            }
            if h < 0 { h += 360 }
        }
        let s = mx == 0 ? 0 : d / mx
        return HSV(h: Int(h.rounded()) % 360, s: Int((s * 1000).rounded()), v: Int((mx * 1000).rounded()))
    }
}

/// Which datapoint layout a light uses.
public enum DPProfile: String, Sendable, Equatable, Codable {
    /// DPs 20–24 (`switch_led`, `work_mode`, `bright_value_v2`, `temp_value_v2`, `colour_data_v2`).
    case v2
    /// DPs 1–5 (`switch`, `mode`, `bright`, `temp`, `colour`).
    case legacy

    /// Detects the profile from a DP query result; `nil` if the light does not look like a lamp.
    public static func detect(from dps: DPMap) -> DPProfile? {
        if dps[20] != nil || dps[24] != nil || dps[21]?.stringValue != nil { return .v2 }
        if dps[1]?.boolValue != nil, dps[2] != nil || dps[5] != nil || dps[3] != nil { return .legacy }
        return nil
    }
}

/// The light's state in Tuya units.
public struct LightState: Sendable, Equatable, Codable {
    public var power: Bool
    public var mode: LightMode
    /// Color-mode color; `hsv.v` is the color brightness.
    public var hsv: HSV
    /// 10–1000.
    public var whiteBrightness: Int
    /// 0 (warm) – 1000 (cold).
    public var temp: Int

    public init(
        power: Bool = false, mode: LightMode = .white, hsv: HSV = HSV(h: 0, s: 1000, v: 1000), whiteBrightness: Int = 1000, temp: Int = 500
    ) {
        self.power = power
        self.mode = mode
        self.hsv = hsv
        self.whiteBrightness = whiteBrightness
        self.temp = temp
    }

    /// Brightness shown by the UI (1–100%) for the current mode.
    public var brightnessPercent: Int {
        let raw = mode == .color ? hsv.v : whiteBrightness
        return max(1, min(100, Int((Double(raw) / 10).rounded())))
    }
}

/// Converts between `LightState` and a profile's datapoints, honoring the light's Kelvin range.
public struct LightCodec: Sendable, Equatable {
    public let profile: DPProfile
    public var kelvinRange: ClosedRange<Int>

    public static let defaultKelvinRange = 2700...6500

    public init(profile: DPProfile, kelvinRange: ClosedRange<Int> = LightCodec.defaultKelvinRange) {
        self.profile = profile
        self.kelvinRange = kelvinRange
    }

    // MARK: Datapoint ids

    public var switchDP: Int { profile == .v2 ? 20 : 1 }
    public var modeDP: Int { profile == .v2 ? 21 : 2 }
    public var brightDP: Int { profile == .v2 ? 22 : 3 }
    public var tempDP: Int { profile == .v2 ? 23 : 4 }
    public var colourDP: Int { profile == .v2 ? 24 : 5 }

    // MARK: Decoding

    /// Applies reported datapoints (full or partial) on top of `base`.
    public func decode(_ dps: DPMap, over base: LightState = LightState()) -> LightState {
        var state = base
        if let on = dps[switchDP]?.boolValue { state.power = on }
        if let m = dps[modeDP]?.stringValue {
            if m == "colour" { state.mode = .color } else if m == "white" { state.mode = .white }
        }
        if let b = dps[brightDP]?.intValue { state.whiteBrightness = whiteBrightness(fromDP: b) }
        if let t = dps[tempDP]?.intValue { state.temp = temp(fromDP: t) }
        if let c = dps[colourDP]?.stringValue, let hsv = decodeColour(c) { state.hsv = hsv }
        return state
    }

    // MARK: Colour

    public func encodeColour(_ hsv: HSV) -> String {
        switch profile {
        case .v2:
            return String(format: "%04x%04x%04x", hsv.h, hsv.s, hsv.v)
        case .legacy:
            let rgb = hsv.rgb
            let s = Int((Double(hsv.s) * 255 / 1000).rounded()), v = Int((Double(hsv.v) * 255 / 1000).rounded())
            return String(format: "%02x%02x%02x%04x%02x%02x", rgb.r, rgb.g, rgb.b, hsv.h, s, v)
        }
    }

    public func decodeColour(_ string: String) -> HSV? {
        switch profile {
        case .v2:
            guard string.count == 12, string.allSatisfy(\.isHexDigit) else { return nil }
            let c = Array(string)
            guard let h = Int(String(c[0..<4]), radix: 16), let s = Int(String(c[4..<8]), radix: 16),
                let v = Int(String(c[8..<12]), radix: 16)
            else { return nil }
            return HSV(h: h, s: s, v: v)
        case .legacy:
            guard string.count == 14, string.allSatisfy(\.isHexDigit) else { return nil }
            let c = Array(string)
            guard let h = Int(String(c[6..<10]), radix: 16), let s = Int(String(c[10..<12]), radix: 16),
                let v = Int(String(c[12..<14]), radix: 16)
            else { return nil }
            return HSV(h: h, s: Int((Double(s) * 1000 / 255).rounded()), v: Int((Double(v) * 1000 / 255).rounded()))
        }
    }

    // MARK: White brightness (internal scale 10–1000)

    public func dp(whiteBrightness wb: Int) -> Int {
        let wb = max(10, min(1000, wb))
        switch profile {
        case .v2: return wb
        case .legacy: return 25 + Int((Double(wb - 10) * 230 / 990).rounded())
        }
    }

    public func whiteBrightness(fromDP dp: Int) -> Int {
        switch profile {
        case .v2: return max(10, min(1000, dp))
        case .legacy: return max(10, min(1000, 10 + Int((Double(dp - 25) * 990 / 230).rounded())))
        }
    }

    // MARK: Temperature

    private var tempScale: Double { profile == .v2 ? 1000 : 255 }

    /// Internal temperature 0–1000 → DP value.
    public func dp(temp: Int) -> Int {
        Int((Double(max(0, min(1000, temp))) * tempScale / 1000).rounded())
    }

    public func temp(fromDP dp: Int) -> Int {
        max(0, min(1000, Int((Double(dp) * 1000 / tempScale).rounded())))
    }

    /// Kelvin → internal temperature, clamping Kelvin into the light's range first.
    public func temp(kelvin: Int) -> Int {
        let k = max(kelvinRange.lowerBound, min(kelvinRange.upperBound, kelvin))
        let span = kelvinRange.upperBound - kelvinRange.lowerBound
        return span == 0 ? 0 : Int((Double(k - kelvinRange.lowerBound) * 1000 / Double(span)).rounded())
    }

    public func kelvin(fromTemp temp: Int) -> Int {
        let span = kelvinRange.upperBound - kelvinRange.lowerBound
        return kelvinRange.lowerBound + Int((Double(max(0, min(1000, temp))) * Double(span) / 1000).rounded())
    }

    public func clamp(kelvin: Int) -> Int { max(kelvinRange.lowerBound, min(kelvinRange.upperBound, kelvin)) }
}

extension RGBColor {
    /// Approximate on-screen color of a white color temperature (Tanner Helland's blackbody approximation,
    /// the same formula the reference mockup uses). Used for the readout and the menu bar dot in white mode.
    public init(kelvin: Int) {
        let temp = Double(max(1000, min(40000, kelvin))) / 100
        var r: Double, g: Double, b: Double
        if temp <= 66 {
            r = 255
            g = 99.4708025861 * log(temp) - 161.1195681661
            b = temp <= 19 ? 0 : 138.5177312231 * log(temp - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(temp - 60, -0.1332047592)
            g = 288.1221695283 * pow(temp - 60, -0.0755148492)
            b = 255
        }
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        self.init(r: byte(r), g: byte(g), b: byte(b))
    }
}
