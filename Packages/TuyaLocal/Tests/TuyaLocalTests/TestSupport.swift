import Foundation

extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0)
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = out
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

let testKey = Data("0123456789abcdef".utf8)
