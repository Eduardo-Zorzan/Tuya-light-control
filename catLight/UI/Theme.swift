import SwiftUI
import TuyaLocal

/// Palette and shared styles taken from the reference mockup (dark glass, macOS controls).
enum Theme {
    static let card = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255).opacity(0.58)
    static let cardBorder = Color.white.opacity(0.07)
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let tabActive = Color(red: 0x23 / 255, green: 0x52 / 255, blue: 0x84 / 255)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let amber = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
    static let sky = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    static let gray = Color(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255)
    static let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let secondaryText = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xAA / 255)
    static let width: CGFloat = 356

    static func color(_ rgb: TuyaLocal.RGBColor) -> Color {
        Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

/// Grouped card ("macos-group").
struct GroupCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

extension View {
    func groupCard() -> some View { modifier(GroupCard()) }
}

/// Section title ("ESPECTRO DE COR").
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(Theme.secondaryText)
    }
}
