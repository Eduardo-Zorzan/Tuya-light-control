import Foundation
import TuyaLocal

/// The favorite colors list: shared across lights, newest first, at most `limit`.
struct Favorites: Codable, Equatable, Sendable {
    static let limit = 12
    static let defaultColors = ["#0A84FF", "#BF5AF2", "#FF375F", "#FF9F0A", "#30D158", "#64D2FF", "#FF453A", "#FFD60A"]

    enum SaveResult: Equatable { case added, alreadySaved }

    /// `#RRGGBB`, uppercase.
    private(set) var colors: [String]

    init(colors: [String] = Favorites.defaultColors) { self.colors = colors }

    var count: Int { colors.count }
    var isEmpty: Bool { colors.isEmpty }
    /// "8/12"
    var countLabel: String { "\(count)/\(Self.limit)" }

    static func normalize(_ hex: String) -> String? { RGBColor(hex: hex)?.hex }

    func contains(_ hex: String) -> Bool {
        guard let n = Self.normalize(hex) else { return false }
        return colors.contains(n)
    }

    /// Adds `hex` to the front unless it is already saved; drops the oldest when full.
    @discardableResult
    mutating func save(_ hex: String) -> SaveResult {
        guard let n = Self.normalize(hex), !colors.contains(n) else { return .alreadySaved }
        colors.insert(n, at: 0)
        if colors.count > Self.limit { colors.removeLast(colors.count - Self.limit) }
        return .added
    }

    mutating func delete(_ hex: String) {
        guard let n = Self.normalize(hex) else { return }
        colors.removeAll { $0 == n }
    }
}
