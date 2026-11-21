import Testing

@testable import TuyaLocal

@Suite("Intent → datapoint patches")
struct LightIntentTests {
    let v2 = LightIntents(codec: LightCodec(profile: .v2))
    let legacy = LightIntents(codec: LightCodec(profile: .legacy))
    let onWhite = LightState(power: true, mode: .white, hsv: HSV(h: 240, s: 1000, v: 800), whiteBrightness: 600, temp: 300)
    let onColor = LightState(power: true, mode: .color, hsv: HSV(h: 240, s: 1000, v: 800), whiteBrightness: 600, temp: 300)
    let off = LightState(power: false, mode: .white)

    @Test func powerOnlyTouchesTheSwitch() {
        #expect(v2.power(false) == [20: .bool(false)])
        #expect(v2.power(true) == [20: .bool(true)])
        #expect(legacy.power(false) == [1: .bool(false)])
    }

    @Test func colorSendsModeAndColourInTheSameFrame() {
        let patch = v2.color(hue: 120, saturation: 1000, state: onColor)
        #expect(patch == [21: .string("colour"), 24: .string("0078" + "03e8" + "0320")])  // keeps current v = 800
    }

    @Test func colorChangeTurnsAnOffLightOn() {
        let patch = v2.color(hue: 30, saturation: 900, state: off)
        #expect(patch[20] == .bool(true))
        #expect(patch[21] == .string("colour"))
    }

    @Test func colorChangeOnAnOnLightDoesNotRetouchPower() {
        #expect(v2.color(hue: 30, saturation: 900, state: onWhite)[20] == nil)
    }

    @Test func brightnessInColorModeChangesColourValueOnly() {
        let patch = v2.brightness(percent: 40, state: onColor)
        #expect(patch == [24: .string("00f003e80190")])  // h 240, s 1000, v 400
        #expect(patch[22] == nil)
    }

    @Test func brightnessInWhiteModeChangesWhiteBrightnessOnly() {
        #expect(v2.brightness(percent: 40, state: onWhite) == [22: .int(400)])
        #expect(legacy.brightness(percent: 100, state: onWhite) == [3: .int(255)])
        #expect(legacy.brightness(percent: 1, state: onWhite) == [3: .int(25)])
    }

    @Test func brightnessIsClampedToOneToHundredPercent() {
        #expect(v2.brightness(percent: 0, state: onWhite) == [22: .int(10)])
        #expect(v2.brightness(percent: 500, state: onWhite) == [22: .int(1000)])
    }

    @Test func brightnessChangeTurnsAnOffLightOn() {
        #expect(v2.brightness(percent: 50, state: off)[20] == .bool(true))
    }

    @Test func temperatureSwitchesToWhiteMode() {
        let patch = v2.temperature(kelvin: 4600, state: onColor)
        #expect(patch == [21: .string("white"), 23: .int(500)])
    }

    @Test func warmEndOfRangeShowsTheRangeMinimum() {
        let codec = LightCodec(profile: .v2)
        let patch = v2.temperature(kelvin: 2700, state: onWhite)
        #expect(patch[23] == .int(0))
        #expect(codec.kelvin(fromTemp: codec.temp(fromDP: 0)) == 2700)
    }

    @Test func presetBelowRangeIsClampedToTheWarmEnd() {
        // "Vela" (2400K) on a 2700–6500K light → 2700K.
        let patch = v2.temperature(kelvin: TemperaturePreset.vela.kelvin, state: onWhite)
        #expect(patch[23] == .int(0))
        // "Foco" (6200K) is inside the range.
        #expect(
            v2.temperature(kelvin: TemperaturePreset.foco.kelvin, state: onWhite)[23]
                == .int(Int((Double(6200 - 2700) * 1000 / 3800).rounded())))
        // A preset above the range clamps to the cold end.
        let limited = LightIntents(codec: LightCodec(profile: .v2, kelvinRange: 2700...5000))
        #expect(limited.temperature(kelvin: 6200, state: onWhite)[23] == .int(1000))
    }

    @Test func presetsAreTheDocumentedValues() {
        #expect(TemperaturePreset.allCases.map(\.kelvin) == [2400, 4200, 6200])
        #expect(TemperaturePreset.allCases.map(\.title) == ["Vela", "Leitura", "Foco"])
    }

    @Test func temperatureChangeTurnsAnOffLightOn() {
        #expect(v2.temperature(kelvin: 3000, state: off)[20] == .bool(true))
    }

    @Test func switchingToWhiteRestoresTheLastWhiteTemperature() {
        // Spec: light shows blue, last white was 4200K → white at 4200K.
        let codec = LightCodec(profile: .v2)
        let state = LightState(
            power: true, mode: .color, hsv: HSV(h: 240, s: 1000, v: 1000), whiteBrightness: 700, temp: codec.temp(kelvin: 4200))
        let patch = v2.mode(.white, state: state)
        #expect(patch[21] == .string("white"))
        #expect(abs(codec.kelvin(fromTemp: patch[23]!.intValue!) - 4200) <= 4)  // ~3.8 K per DP step
        #expect(patch[22] == .int(700))
    }

    @Test func switchingToColorRestoresTheLastColor() {
        let patch = v2.mode(.color, state: onWhite)
        #expect(patch == [21: .string("colour"), 24: .string("00f003e80320")])
    }

    @Test func legacyColorPatchUsesLegacyDatapoints() {
        let patch = legacy.color(HSV(h: 0, s: 1000, v: 1000), state: off)
        #expect(patch == [1: .bool(true), 2: .string("colour"), 5: .string("ff00000000ffff")])
    }
}

@Suite("Scenes")
struct SceneTests {
    let v2 = LightIntents(codec: LightCodec(profile: .v2))
    let off = LightState(power: false, mode: .white)

    @Test func sixBuiltInScenesInOrder() {
        #expect(
            LightScene.all.map(\.name) == ["Foco Profundo", "Cyberpunk", "Pôr do Sol", "Leitura Noturna", "Modo Cinema", "Floresta Calma"])
        #expect(Set(LightScene.all.map(\.id)).count == 6)
        #expect(LightScene.all.allSatisfy { !$0.summary.isEmpty })
    }

    @Test func settingsMatchTheSpecTable() {
        let table: [String: LightScene.Setting] = Dictionary(uniqueKeysWithValues: LightScene.all.map { ($0.name, $0.setting) })
        #expect(table["Foco Profundo"] == .white(kelvin: 6200, brightnessPercent: 100))
        #expect(table["Cyberpunk"] == .color(hue: 295, saturationPercent: 92, brightnessPercent: 90))
        #expect(table["Pôr do Sol"] == .color(hue: 26, saturationPercent: 95, brightnessPercent: 70))
        #expect(table["Leitura Noturna"] == .white(kelvin: 2500, brightnessPercent: 45))
        #expect(table["Modo Cinema"] == .color(hue: 228, saturationPercent: 94, brightnessPercent: 30))
        #expect(table["Floresta Calma"] == .color(hue: 145, saturationPercent: 82, brightnessPercent: 60))
    }

    @Test func colorSceneIsOneFrameWithPowerModeAndColour() throws {
        let cyberpunk = try #require(LightScene.all.first { $0.name == "Cyberpunk" })
        let patch = v2.scene(cyberpunk, state: off)
        #expect(patch == [20: .bool(true), 21: .string("colour"), 24: .string("0127" + "0398" + "0384")])
    }

    @Test func whiteSceneOnLimitedLightClampsTo2700K() throws {
        // "Leitura Noturna" is 2500K; a 2700–6500K light shows 2700K at 45%.
        let leitura = try #require(LightScene.all.first { $0.name == "Leitura Noturna" })
        let patch = v2.scene(leitura, state: off)
        #expect(patch == [20: .bool(true), 21: .string("white"), 23: .int(0), 22: .int(450)])
    }

    @Test func whiteSceneWithinRangeKeepsItsTemperature() throws {
        let foco = try #require(LightScene.all.first { $0.name == "Foco Profundo" })
        let codec = LightCodec(profile: .v2)
        let patch = v2.scene(foco, state: off)
        #expect(codec.kelvin(fromTemp: patch[23]!.intValue!) == 6200)
        #expect(patch[22] == .int(1000))
    }

    @Test func sceneAlwaysTurnsTheLightOnEvenIfAlreadyOn() throws {
        let cinema = try #require(LightScene.all.first { $0.name == "Modo Cinema" })
        #expect(v2.scene(cinema, state: LightState(power: true))[20] == .bool(true))
    }

    @Test func everySceneProducesValidDatapointsOnBothProfiles() {
        for profile in [DPProfile.v2, .legacy] {
            let codec = LightCodec(profile: profile)
            let intents = LightIntents(codec: codec)
            for scene in LightScene.all {
                let state = codec.decode(intents.scene(scene, state: off))
                #expect(state.power)
                switch scene.setting {
                case .white(let k, let p):
                    #expect(state.mode == .white)
                    #expect(abs(codec.kelvin(fromTemp: state.temp) - codec.clamp(kelvin: k)) <= 4)
                    #expect(state.brightnessPercent == p)
                case .color(let h, let s, let p):
                    #expect(state.mode == .color)
                    #expect(state.hsv.h == h)
                    #expect(abs(state.hsv.s - s * 10) <= 4)
                    #expect(state.brightnessPercent == p)
                }
            }
        }
    }
}
