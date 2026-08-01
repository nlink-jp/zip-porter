import Foundation

/// PKWARE "traditional" ZIP encryption (APPNOTE §6.1) — the only scheme
/// Windows Explorer can open standalone. Cryptographically weak (known-
/// plaintext attacks); provided strictly for compatibility, and callers
/// must surface a warning when producing it.
public struct ZipCryptoCipher {
    public static let headerSize = 12

    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    private mutating func update(with byte: UInt8) {
        key0 = Self.crc32(key0, byte)
        key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
        key2 = Self.crc32(key2, UInt8(key1 >> 24))
    }

    private static func crc32(_ key: UInt32, _ byte: UInt8) -> UInt32 {
        CRC32.table[Int((key ^ UInt32(byte)) & 0xFF)] ^ (key >> 8)
    }

    private var keystreamByte: UInt8 {
        let temp = UInt16(key2 & 0xFFFF) | 2
        return UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
    }

    private init(password: String) {
        for byte in Array(password.utf8) { update(with: byte) }
    }

    /// Decrypting init: consumes the 12-byte encryption header and verifies
    /// the check byte. Returns nil when the password is (almost certainly)
    /// wrong — the check is a single byte, so 1/256 wrong passwords pass
    /// here and fail CRC later.
    public init?(password: String, header: Data, checkByte: UInt8) {
        self.init(password: password)
        var last: UInt8 = 0
        for byte in header {
            last = byte ^ keystreamByte
            update(with: last)
        }
        guard last == checkByte else { return nil }
    }

    /// Encrypting init: emits the 12-byte encryption header (11 random bytes
    /// + the check byte) into `header`.
    public init(password: String, randomBytes: Data, checkByte: UInt8, header out: inout Data) {
        precondition(randomBytes.count == Self.headerSize - 1)
        self.init(password: password)
        for byte in randomBytes + [checkByte] {
            let c = byte ^ keystreamByte
            update(with: byte)
            out.append(c)
        }
    }

    public mutating func decrypt(_ chunk: Data) -> Data {
        var out = Data(capacity: chunk.count)
        for byte in chunk {
            let p = byte ^ keystreamByte
            update(with: p)
            out.append(p)
        }
        return out
    }

    public mutating func encrypt(_ chunk: Data) -> Data {
        var out = Data(capacity: chunk.count)
        for byte in chunk {
            let c = byte ^ keystreamByte
            update(with: byte)
            out.append(c)
        }
        return out
    }
}
