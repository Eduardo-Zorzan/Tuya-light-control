import Testing

@testable import TuyaLocal

@Suite("Profile detection")
struct ProfileDetectionTests {
    @Test func v2Profile() {
        #expect(
            DPProfile.detect(from: [20: .bool(true), 21: .string("white"), 22: .int(500), 23: .int(0), 24: .string("000003e803e8")]) == .v2)
    }
    @Test func legacyProfile() {
        #expect(
            DPProfile.detect(from: [1: .bool(true), 2: .string("white"), 3: .int(255), 4: .int(0), 5: .string("ffffff000003e803e8")])
                == .legacy)
    }
    @Test func unknownProfile() {
        #expect(DPProfile.detect(from: [101: .int(3)]) == nil)
        #expect(DPProfile.detect(from: [:]) == nil)
    }
}

@Suite("Colour conversions")
struct ColourTests {
    @Test func hexParsing() {
        #expect(RGBColor(hex: "#0A84FF") == RGBColor(r: 10, g: 132, b: 255))
        #expect(RGBColor(hex: "ff375f") == RGBColor(r: 255, g: 55, b: 95))
        #expect(RGBColor(hex: " #FF375F ")?.hex == "#FF375F")
        #expect(RGBColor(r: 10, g: 132, b: 255).hex == "#0A84FF")
    }

    @Test(arguments: ["#ZZ12", "#12", "", "#12345", "#1234567", "#GGGGGG", "12 456", "#-12345"])
    func invalidHexIsRejected(_ text: String) {
        #expect(RGBColor(hex: text) == nil)
    }

    @Test func primaryColorsAsHSV() {
        #expect(RGBColor(r: 255, g: 0, b: 0).hsv == HSV(h: 0, s: 1000, v: 1000))
        #expect(RGBColor(r: 0, g: 255, b: 0).hsv == HSV(h: 120, s: 1000, v: 1000))
        #expect(RGBColor(r: 0, g: 0, b: 255).hsv == HSV(h: 240, s: 1000, v: 1000))
        #expect(RGBColor(r: 255, g: 255, b: 255).hsv == HSV(h: 0, s: 0, v: 1000))
        #expect(RGBColor(r: 0, g: 0, b: 0).hsv == HSV(h: 0, s: 0, v: 0))
    }

    @Test func hsvToRGBPrimaries() {
        #expect(HSV(h: 0, s: 1000, v: 1000).rgb == RGBColor(r: 255, g: 0, b: 0))
        #expect(HSV(h: 120, s: 1000, v: 1000).rgb == RGBColor(r: 0, g: 255, b: 0))
        #expect(HSV(h: 240, s: 1000, v: 500).rgb == RGBColor(r: 0, g: 0, b: 128))
        #expect(HSV(h: 360, s: 1000, v: 1000).rgb == RGBColor(r: 255, g: 0, b: 0))  // 360° wraps to red
    }

    @Test func rgbHsvRoundTripIsCloseForEveryHue() {
        for h in stride(from: 0, to: 360, by: 5) {
            let original = HSV(h: h, s: 800, v: 900)
            let back = original.rgb.hsv
            let diff = min(abs(back.h - original.h), 360 - abs(back.h - original.h))
            #expect(diff <= 1, "hue \(h) -> \(back.h)")
            #expect(abs(back.s - original.s) <= 8)
            #expect(abs(back.v - original.v) <= 3)
        }
    }
}

@Suite("LightCodec round trips")
struct LightCodecTests {
    @Test(arguments: [DPProfile.v2, .legacy])
    func colourRoundTripsForEveryHue(profile: DPProfile) throws {
        let codec = LightCodec(profile: profile)
        for h in stride(from: 0, through: 360, by: 3) {
            for (s, v) in [(0, 10), (500, 500), (1000, 1000), (920, 900)] {
                let hsv = HSV(h: h, s: s, v: v)
                let back = try #require(codec.decodeColour(codec.encodeColour(hsv)))
                #expect(back.h == hsv.h)
                // Legacy stores s/v on a 0–255 scale: resolution is ~4 of 1000.
                let tolerance = profile == .v2 ? 0 : 4
                #expect(abs(back.s - hsv.s) <= tolerance)
                #expect(abs(back.v - hsv.v) <= tolerance)
            }
        }
    }

    @Test func v2ColourFormatMatchesTheDeviceString() {
        let codec = LightCodec(profile: .v2)
        #expect(codec.encodeColour(HSV(h: 295, s: 920, v: 900)) == "012703980384")
        #expect(codec.encodeColour(HSV(h: 0, s: 1000, v: 1000)) == "000003e803e8")
        #expect(codec.decodeColour("003d03e803e8") == HSV(h: 61, s: 1000, v: 1000))
    }

    @Test func legacyColourFormatCarriesRGBPlusHSV() {
        let codec = LightCodec(profile: .legacy)
        let encoded = codec.encodeColour(HSV(h: 0, s: 1000, v: 1000))
        #expect(encoded == "ff00000000ffff")  // rrggbb + 0hhh + ss + vv
        #expect(encoded.count == 14)
        #expect(codec.decodeColour(encoded) == HSV(h: 0, s: 1000, v: 1000))
    }

    @Test(arguments: [DPProfile.v2, .legacy])
    func malformedColourStringsAreRejected(profile: DPProfile) {
        let codec = LightCodec(profile: profile)
        for bad in ["", "xyz", "00", "zzzzzzzzzzzz", "0000000000000000000000"] { #expect(codec.decodeColour(bad) == nil) }
    }

    @Test(arguments: [DPProfile.v2, .legacy])
    func brightnessPercentRoundTripsForWhiteAndColor(profile: DPProfile) {
        let codec = LightCodec(profile: profile)
        for p in 1...100 {
            // White mode: percent -> bright DP -> percent
            let dp = codec.dp(whiteBrightness: p * 10)
            let white = LightState(mode: .white, whiteBrightness: codec.whiteBrightness(fromDP: dp))
            #expect(white.brightnessPercent == p, "white \(p)% -> dp \(dp)")
            // Color mode: percent -> colour string -> percent
            let hsv = codec.decodeColour(codec.encodeColour(HSV(h: 200, s: 800, v: p * 10)))!
            #expect(LightState(mode: .color, hsv: hsv).brightnessPercent == p, "color \(p)%")
        }
    }

    @Test func whiteBrightnessDPRangeEdges() {
        let v2 = LightCodec(profile: .v2), legacy = LightCodec(profile: .legacy)
        #expect(v2.dp(whiteBrightness: 10) == 10 && v2.dp(whiteBrightness: 1000) == 1000)
        #expect(legacy.dp(whiteBrightness: 10) == 25 && legacy.dp(whiteBrightness: 1000) == 255)
        #expect(v2.dp(whiteBrightness: 0) == 10)  // clamped to the device minimum
        #expect(legacy.dp(whiteBrightness: 5000) == 255)
    }

    @Test(arguments: [DPProfile.v2, .legacy])
    func temperatureDPRoundTrips(profile: DPProfile) {
        let codec = LightCodec(profile: profile)
        for t in stride(from: 0, through: 1000, by: 10) {
            let back = codec.temp(fromDP: codec.dp(temp: t))
            #expect(abs(back - t) <= (profile == .v2 ? 0 : 3), "temp \(t)")
        }
        #expect(codec.dp(temp: 0) == 0)
        #expect(codec.dp(temp: 1000) == (profile == .v2 ? 1000 : 255))
    }

    @Test func kelvinMapsThroughThePerLightRange() {
        let std = LightCodec(profile: .v2)  // 2700–6500
        #expect(std.temp(kelvin: 2700) == 0)
        #expect(std.temp(kelvin: 6500) == 1000)
        #expect(std.temp(kelvin: 4600) == 500)
        #expect(std.kelvin(fromTemp: 0) == 2700 && std.kelvin(fromTemp: 1000) == 6500 && std.kelvin(fromTemp: 500) == 4600)
        // Per-light range (e.g. 2000–7000K bulb)
        let wide = LightCodec(profile: .v2, kelvinRange: 2000...7000)
        #expect(wide.temp(kelvin: 2000) == 0 && wide.temp(kelvin: 7000) == 1000)
        #expect(wide.kelvin(fromTemp: 500) == 4500)
        // Clamping at range edges
        #expect(std.temp(kelvin: 1000) == 0)
        #expect(std.temp(kelvin: 9000) == 1000)
        #expect(std.clamp(kelvin: 2400) == 2700)
    }

    @Test func kelvinRoundTripsWithinResolution() {
        let codec = LightCodec(profile: .v2)
        for k in stride(from: 2700, through: 6500, by: 50) {
            #expect(abs(codec.kelvin(fromTemp: codec.temp(kelvin: k)) - k) <= 3)
        }
    }

    @Test func decodeAppliesFullAndPartialReports() {
        let codec = LightCodec(profile: .v2)
        let full = codec.decode([20: .bool(true), 21: .string("colour"), 22: .int(400), 23: .int(250), 24: .string("0078032003e8")])
        #expect(full == LightState(power: true, mode: .color, hsv: HSV(h: 120, s: 800, v: 1000), whiteBrightness: 400, temp: 250))
        // A push with only the power DP keeps everything else.
        let off = codec.decode([20: .bool(false)], over: full)
        #expect(off.power == false && off.hsv == full.hsv && off.mode == .color)
        // Unknown mode values (scene/music) keep the previous mode.
        #expect(codec.decode([21: .string("scene")], over: full).mode == .color)
    }

    @Test func decodeLegacyReport() {
        let codec = LightCodec(profile: .legacy)
        let s = codec.decode([1: .bool(true), 2: .string("white"), 3: .int(255), 4: .int(0)])
        #expect(s.power && s.mode == .white && s.whiteBrightness == 1000 && s.temp == 0)
    }
}

@Suite("Kelvin to RGB")
struct KelvinColorTests {
    /// Expected values computed with the reference mockup's JavaScript `kelvinToRgb`.
    @Test(arguments: [(2400, "#FF9B3D"), (2700, "#FFA757"), (4200, "#FFD3AF"), (6200, "#FFF9F2"), (6500, "#FFFEFA")])
    func matchesTheMockupAtKeyTemperatures(kelvin: Int, hex: String) {
        #expect(RGBColor(kelvin: kelvin).hex == hex)
    }

    @Test func warmIsRedderThanCold() {
        let warm = RGBColor(kelvin: 2400), cold = RGBColor(kelvin: 6500)
        #expect(warm.r == 255 && warm.b < cold.b)
    }
}
