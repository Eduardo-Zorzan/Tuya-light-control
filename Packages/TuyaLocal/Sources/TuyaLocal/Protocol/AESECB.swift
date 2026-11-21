import CommonCrypto
import Foundation

/// AES-128-ECB via CommonCrypto (CryptoKit has no ECB).
enum AESECB {
    enum Failure: Error { case badKeyLength, cryptFailed(Int32) }

    static func encrypt(_ data: Data, key: Data, pad: Bool = true) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), data, key: key, pad: pad)
    }

    static func decrypt(_ data: Data, key: Data, pad: Bool = true) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), data, key: key, pad: pad)
    }

    private static func crypt(_ op: CCOperation, _ data: Data, key: Data, pad: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw Failure.badKeyLength }
        let options = CCOptions(kCCOptionECBMode) | (pad ? CCOptions(kCCOptionPKCS7Padding) : 0)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        op, CCAlgorithm(kCCAlgorithmAES), options,
                        keyPtr.baseAddress, key.count, nil,
                        inPtr.baseAddress, data.count,
                        outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.cryptFailed(status) }
        return out.prefix(moved)
    }
}
