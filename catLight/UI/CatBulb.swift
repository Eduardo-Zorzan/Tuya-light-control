import AppKit
import SwiftUI

/// The cat-shaped light bulb from the mockup (64×64 artwork for the popover emblem, 48×48 for the menu bar).
enum CatBulbArt {
    // 64×64 emblem
    static let body = SVGPath.path(
        "M16.5 24.5L13.2 9.5C12.8 7.7 14.6 6.3 16.3 7.2L26 12.2C27.9 11.7 29.9 11.4 32 11.4C34.1 11.4 36.1 11.7 38 12.2L47.7 7.2C49.4 6.3 51.2 7.7 50.8 9.5L47.5 24.5C49.8 27.3 51.2 30.8 51.2 34.6C51.2 41.4 46.6 45.8 42.6 49.5H21.4C17.4 45.8 12.8 41.4 12.8 34.6C12.8 30.8 14.2 27.3 16.5 24.5Z"
    )
    static let earLeft = SVGPath.path("M17.2 19.5L15.6 11.8L22.2 15.2C20.2 16.3 18.5 17.8 17.2 19.5Z")
    static let earRight = SVGPath.path("M46.8 19.5L48.4 11.8L41.8 15.2C43.8 16.3 45.5 17.8 46.8 19.5Z")
    static let nose = SVGPath.path(
        "M30.6 36.2C30.6 35.5 31.2 35.1 32 35.1C32.8 35.1 33.4 35.5 33.4 36.2C33.4 36.9 32.6 37.5 32 37.5C31.4 37.5 30.6 36.9 30.6 36.2Z")
    static let mouth = SVGPath.path("M28.5 39C29.6 40.5 31.3 40.2 32 38.4C32.7 40.2 34.4 40.5 35.5 39")
    static let whiskers = SVGPath.path("M16.2 35.2L20.2 35.8M16.6 38.8L20.4 38.4M47.8 35.2L43.8 35.8M47.4 38.8L43.6 38.4")
    static let capUpper = Path(roundedRect: CGRect(x: 22.5, y: 51.2, width: 19, height: 3.2), cornerRadius: 1.6)
    static let capLower = Path(roundedRect: CGRect(x: 24, y: 55.4, width: 16, height: 3), cornerRadius: 1.5)
    static let capTip = SVGPath.path("M27.5 59.5H36.5C36 61.2 34.2 62.2 32 62.2C29.8 62.2 28 61.2 27.5 59.5Z")

    // 48×48 menu bar glyph
    static let barBody = SVGPath.path(
        "M12.5 18.5L10.2 7.5C9.9 6.2 11.2 5.2 12.4 5.8L19.6 9.5C21 9.1 22.5 8.9 24 8.9C25.5 8.9 27 9.1 28.4 9.5L35.6 5.8C36.8 5.2 38.1 6.2 37.8 7.5L35.5 18.5C37.2 20.6 38.2 23.2 38.2 26C38.2 31.1 34.8 34.4 31.8 37.2H16.2C13.2 34.4 9.8 31.1 9.8 26C9.8 23.2 10.8 20.6 12.5 18.5Z"
    )
    static let barMouth = SVGPath.path("M21.5 29.5C22.4 30.6 23.6 30.4 24 29.2C24.4 30.4 25.6 30.6 26.5 29.5")
    static let barWhiskers = SVGPath.path("M12.5 26.5H15.5M12.8 29.2H15.5M35.5 26.5H32.5M35.2 29.2H32.5")
    static let barCapUpper = Path(roundedRect: CGRect(x: 17.5, y: 39, width: 13, height: 2.4), cornerRadius: 1.2)
    static let barCapLower = Path(roundedRect: CGRect(x: 19, y: 42.5, width: 10, height: 2.4), cornerRadius: 1.2)
}

/// Popover emblem: the bulb takes `tint` (the light color) with a soft halo behind it.
struct CatBulbEmblem: View {
    var tint: Color
    var haloOpacity: Double
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(tint).frame(width: 64, height: 64).blur(radius: 18).opacity(haloOpacity)
            Canvas { ctx, canvasSize in
                let scale = canvasSize.width / 64
                ctx.scaleBy(x: scale, y: scale)
                let ink = Color(red: 0.094, green: 0.094, blue: 0.106)
                ctx.fill(CatBulbArt.body, with: .color(tint))
                ctx.fill(CatBulbArt.earLeft, with: .color(Color(red: 0.11, green: 0.11, blue: 0.118).opacity(0.32)))
                ctx.fill(CatBulbArt.earRight, with: .color(Color(red: 0.11, green: 0.11, blue: 0.118).opacity(0.32)))
                var gloss = Path(ellipseIn: CGRect(x: 21.5 - 4.2, y: 22.5 - 2.1, width: 8.4, height: 4.2))
                gloss = gloss.applying(
                    CGAffineTransform(translationX: -21.5, y: -22.5).rotated(by: -36 * .pi / 180).translatedBy(x: 21.5, y: 22.5)
                        .concatenating(.identity))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: 17.3, y: 20.4, width: 8.4, height: 4.2)).applying(
                        CGAffineTransform(translationX: 21.5, y: 22.5).rotated(by: -36 * .pi / 180).translatedBy(x: -21.5, y: -22.5)),
                    with: .color(.white.opacity(0.55)))
                ctx.fill(Path(ellipseIn: CGRect(x: 16.5, y: 25.9, width: 2.6, height: 2.6)), with: .color(.white.opacity(0.45)))
                for cx in [25.0, 39.0] {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.2, y: 29.3, width: 6.4, height: 6.4)), with: .color(ink))
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 1 - 1.1, y: 30.3, width: 2.2, height: 2.2)), with: .color(.white))
                }
                ctx.fill(CatBulbArt.nose, with: .color(ink))
                ctx.stroke(CatBulbArt.mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                ctx.stroke(CatBulbArt.whiskers, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.fill(CatBulbArt.capUpper, with: .color(Color(red: 0.831, green: 0.831, blue: 0.847)))
                ctx.fill(CatBulbArt.capLower, with: .color(Color(red: 0.631, green: 0.631, blue: 0.667)))
                ctx.fill(CatBulbArt.capTip, with: .color(Color(red: 0.443, green: 0.443, blue: 0.478)))
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: 5, y: 3)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Menu bar image: monochrome cat-bulb glyph (eyes/muzzle cut out) plus a colored status dot.
enum StatusItemImage {
    /// - Parameters:
    ///   - glyph: color of the glyph (the menu bar's label color for the current appearance).
    ///   - dot: color of the status dot, or `nil` for gray.
    static func make(glyph: NSColor, dot: NSColor?) -> NSImage {
        let size = NSSize(width: 27, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s: CGFloat = 18.0 / 48.0
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            ctx.setFillColor(glyph.cgColor)
            ctx.addPath(CatBulbArt.barBody.cgPath)
            ctx.fillPath()
            ctx.addPath(CatBulbArt.barCapUpper.cgPath)
            ctx.addPath(CatBulbArt.barCapLower.cgPath)
            ctx.fillPath()
            // Cut-outs: eyes, mouth, whiskers.
            ctx.setBlendMode(.clear)
            for cx in [19.0, 29.0] { ctx.fillEllipse(in: CGRect(x: cx - 2.2, y: 24.5 - 2.2, width: 4.4, height: 4.4)) }
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.9)
            ctx.addPath(CatBulbArt.barMouth.cgPath)
            ctx.strokePath()
            ctx.setLineWidth(1.6)
            ctx.addPath(CatBulbArt.barWhiskers.cgPath)
            ctx.strokePath()
            ctx.restoreGState()
            // Status dot
            ctx.setBlendMode(.normal)
            let dotColor = dot ?? NSColor(white: 0.5, alpha: 1)
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: 20, y: 6, width: 6, height: 6))
            return true
        }
        image.isTemplate = false
        return image
    }
}
