import SwiftUI
import Testing
import TuyaLocal

@testable import catLight

/// Renders the popover in several states to PNGs (in the test container's tmp) for visual review.
@MainActor
@Suite("UI snapshots")
struct SnapshotTests {
    static func outputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("catlight-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func render(_ name: String, _ view: some View) throws {
        let framed =
            view
            .background(Color(red: 0.11, green: 0.11, blue: 0.118))  // stands in for the popover material
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: Self.outputDir().appendingPathComponent("\(name).png"))
        #expect(image.width >= Int(Theme.width) * 2)
    }

    func harness(dps: DPMap) async throws -> Harness {
        let h = try await Harness.make()
        await h.connected("a", dps: dps)
        return h
    }

    @Test func luzColorMode() async throws {
        let h = try await harness(dps: [20: .bool(true), 21: .string("colour"), 22: .int(600), 23: .int(500), 24: .string("00d203e80352")])
        try render("luz-color", RootView(model: h.model))
    }

    @Test func luzWhiteMode() async throws {
        let h = try await harness(dps: [20: .bool(true), 21: .string("white"), 22: .int(850), 23: .int(395), 24: .string("00d203e80352")])
        try render("luz-white", RootView(model: h.model))
    }

    @Test func luzOffline() async throws {
        let h = try await Harness.make()
        await h.manager.emit(.status(deviceID: "a", .offline(nextRetry: Date().addingTimeInterval(12))))
        await h.manager.emit(.event(deviceID: "a", .applyFailed))
        _ = await eventually { h.model.hasUnappliedChange }
        try render("luz-offline", RootView(model: h.model))
    }

    @Test func scenes() async throws {
        let h = try await harness(dps: FakeDefaults.v2On)
        h.model.applyScene(LightScene.all[1])
        try render("cenas", RootView(model: h.model, initialTab: .cenas))
    }

    @Test func settings() async throws {
        let h = try await Harness.make(lights: [("a", "Fita LED Mesa"), ("b", "Lâmpada Estúdio")])
        await h.connected("a")
        await h.manager.emit(.status(deviceID: "b", .error(.invalidKey, nextRetry: Date().addingTimeInterval(8))))
        try await Task.sleep(for: .milliseconds(80))
        try render("ajustes", RootView(model: h.model, initialTab: .ajustes))
    }

    @Test func firstRun() async throws {
        let h = try await Harness.make(lights: [])
        try render("setup", RootView(model: h.model))
    }

    @Test func addForm() async throws {
        let h = try await Harness.make(lights: [])
        try render("form", RootView(model: h.model, initialRoute: .addManual))
    }

    @Test func localNetworkDenied() async throws {
        let h = try await Harness.make()
        await h.manager.emit(.status(deviceID: "a", .error(.localNetworkDenied, nextRetry: Date().addingTimeInterval(5))))
        _ = await eventually { h.model.localNetworkDenied }
        try render("rede-local", RootView(model: h.model))
    }

    @Test func menuBarIcons() throws {
        let image = StatusItemImage.make(glyph: .white, dot: NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1))
        let gray = StatusItemImage.make(glyph: .white, dot: nil)
        let view = HStack(spacing: 20) {
            Image(nsImage: image).scaleEffect(6)
            Image(nsImage: gray).scaleEffect(6)
        }
        .padding(60).background(Color(white: 0.15))
        try render("menubar-icons", view.frame(width: 356))
    }
}
