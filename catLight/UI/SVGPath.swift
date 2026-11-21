import SwiftUI

/// Minimal SVG path-data parser (absolute and relative M, L, H, V, C, Z) so the mockup's artwork can be reused as-is.
enum SVGPath {
    static func path(_ d: String) -> Path {
        var path = Path()
        var tokens = tokenize(d)[...]
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        func number() -> CGFloat? {
            guard case .number(let n)? = tokens.first else { return nil }
            tokens.removeFirst()
            return CGFloat(n)
        }

        while let token = tokens.first {
            if case .command(let c) = token {
                command = c
                tokens.removeFirst()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                }
                continue
            }
            let rel = command.isLowercase
            switch command.uppercased() {
            case "M":
                guard let x = number(), let y = number() else { return path }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                start = current
                path.move(to: current)
                command = rel ? "l" : "L"  // subsequent pairs are implicit line-tos
            case "L":
                guard let x = number(), let y = number() else { return path }
                current = rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
            case "H":
                guard let x = number() else { return path }
                current.x = rel ? current.x + x : x
                path.addLine(to: current)
            case "V":
                guard let y = number() else { return path }
                current.y = rel ? current.y + y : y
                path.addLine(to: current)
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else {
                    return path
                }
                let o = rel ? current : .zero
                let end = CGPoint(x: o.x + x, y: o.y + y)
                path.addCurve(to: end, control1: CGPoint(x: o.x + x1, y: o.y + y1), control2: CGPoint(x: o.x + x2, y: o.y + y2))
                current = end
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private enum Token {
        case command(Character)
        case number(Double)
    }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var buffer = ""
        func flush() {
            if let n = Double(buffer) { out.append(.number(n)) }
            buffer = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush()
                out.append(.command(ch))
            } else if ch == "-" {
                flush()
                buffer = "-"
            } else if ch == " " || ch == "," || ch == "\n" {
                flush()
            } else if ch == "." && buffer.contains(".") {
                flush()
                buffer = "."
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return out
    }
}
