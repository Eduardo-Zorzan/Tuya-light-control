import Testing
import TuyaLocal

@testable import catLight

@Test func appTargetLinksTheTuyaLocalPackage() {
    #expect(LightScene.all.count == 6)
}
