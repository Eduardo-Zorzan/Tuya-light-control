import CoreGraphics
import SwiftUI
import TuyaLocal

/// HSV disk (value 100%) rendered once to a bitmap; drag picks hue (angle) and saturation (distance).
struct ColorWheel: View {
    var hue: Int  // 0...360
    var saturation: Int  // 0...1000
    var cursorColor: Color
    var dimmed: Bool
    var onPick: (_ hue: Int, _ saturation: Int) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    static let diameter: CGFloat = 152
    @State private var dragging = false

    var body: some View {
        let radius = Self.diameter / 2
        let angle = Double(hue) * .pi / 180
        let dist = Double(saturation) / 1000 * (radius - 4)
        ZStack {
            Image(decorative: Self.image, scale: 2)
                .interpolation(.high)
                .frame(width: Self.diameter, height: Self.diameter)
                .opacity(dimmed ? 0.55 : 1)
            Circle()
                .fill(cursorColor)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                .position(x: radius + cos(angle) * dist, y: radius + sin(angle) * dist)
                .allowsHitTesting(false)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    let (h, s) = Self.pick(at: drag.location, diameter: Self.diameter)
                    onPick(h, s)
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Roda de cores")
        .accessibilityValue("matiz \(hue) graus, saturação \(saturation / 10) por cento")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 10 : -10
            onPick((hue + delta + 360) % 360, saturation)
        }
    }

    /// Hue/saturation for a pointer location inside the disk (angle from +x, clockwise on screen — as in the mockup).
    static func pick(at point: CGPoint, diameter: CGFloat) -> (hue: Int, saturation: Int) {
        let radius = diameter / 2
        let dx = point.x - radius, dy = point.y - radius
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let dist = min(radius, (dx * dx + dy * dy).squareRoot())
        return (Int(degrees.rounded()) % 360, Int((dist / radius * 1000).rounded()))
    }

    /// 2× bitmap of the disk, built once.
    static let image: CGImage = {
        let px = Int(diameter * 2)
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let r = Double(px) / 2
        for y in 0..<px {
            for x in 0..<px {
                let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                let d = (dx * dx + dy * dy).squareRoot()
                guard d <= r else { continue }
                var a = atan2(dy, dx) * 180 / .pi
                if a < 0 { a += 360 }
                let rgb = HSV(h: Int(a.rounded()) % 360, s: Int(d / r * 1000), v: 1000).rgb
                let i = (y * px + x) * 4
                data[i] = rgb.r; data[i + 1] = rgb.g; data[i + 2] = rgb.b; data[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }()
}
