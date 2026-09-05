import Foundation

/// ZIP format constants and entry metadata shared by the reader and writer.
/// Reference: PKWARE APPNOTE.TXT 6.3.x and the WinZip AES spec (AE-2).
public enum Zip {
    public static let localHeaderSignature: UInt32 = 0x0403_4B50
    public static let centralHeaderSignature: UInt32 = 0x0201_4B50
    public static let eocdSignature: UInt32 = 0x0605_4B50
    public static let zip64EOCDSignature: UInt32 = 0x0606_4B50
    public static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    public static let dataDescriptorSignature: UInt32 = 0x0807_4B50

    /// General purpose bit flags.
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let encrypted = Flags(rawValue: 1 << 0)
        public static let dataDescriptor = Flags(rawValue: 1 << 3)
        public static let utf8Name = Flags(rawValue: 1 << 11)
    }

    public enum Method: Equatable, Sendable {
        case store
        case deflate
        /// Method 99: WinZip AES wrapper; the real method is in the 0x9901 extra field.
        case aes
        case other(UInt16)

        public init(rawValue: UInt16) {
            switch rawValue {
            case 0: self = .store
            case 8: self = .deflate
            case 99: self = .aes
            default: self = .other(rawValue)
            }
        }

        public var rawValue: UInt16 {
            switch self {
            case .store: return 0
            case .deflate: return 8
            case .aes: return 99
            case .other(let v): return v
            }
        }
    }

    /// Extra-field IDs we understand.
    public enum ExtraID {
        public static let zip64: UInt16 = 0x0001
        public static let aes: UInt16 = 0x9901
    }

    /// AES key strengths from the 0x9901 extra field.
    public enum AESStrength: UInt8, Sendable, Equatable {
        case aes128 = 1
        case aes192 = 2
        case aes256 = 3

        public var keyBytes: Int {
            switch self {
            case .aes128: return 16
            case .aes192: return 24
            case .aes256: return 32
            }
        }

        public var saltBytes: Int { keyBytes / 2 }
    }

    /// How an entry's data is protected.
    public enum Encryption: Equatable, Sendable {
        case none
        case zipCrypto
        /// vendorVersion 1 = AE-1 (CRC present), 2 = AE-2 (CRC zeroed).
        case aes(strength: AESStrength, vendorVersion: UInt8, actualMethod: UInt16)
    }
}

/// One central-directory entry, with raw name bytes preserved for encoding
/// detection (the decoded name is decided per archive, not per entry).
public struct ZipEntry: Sendable {
    public var rawName: Data
    public var flags: Zip.Flags
    public var method: Zip.Method
    public var dosTime: UInt16
    public var dosDate: UInt16
    public var crc32: UInt32
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var localHeaderOffset: UInt64
    public var externalAttributes: UInt32
    public var versionMadeBy: UInt16
    public var encryption: Zip.Encryption
    /// Absolute offset of the entry's payload, resolved from the *local*
    /// header when the archive is opened (ADR-0005). The local header's name
    /// and extra lengths may differ from the central directory's, and this
    /// is the one place that difference is reconciled: the overlap/EOF check
    /// and `extract` both read from here.
    public var dataOffset: UInt64 = 0

    /// True when the entry is a directory (trailing slash — the convention
    /// every mainstream tool follows).
    public var isDirectory: Bool {
        rawName.last == UInt8(ascii: "/")
    }

    /// Unix mode bits when the entry was made on Unix (upper 16 bits of the
    /// external attributes); nil otherwise.
    public var unixMode: UInt16? {
        let hostOS = versionMadeBy >> 8
        guard hostOS == 3 || hostOS == 19 else { return nil } // Unix, macOS
        let mode = UInt16(externalAttributes >> 16)
        return mode == 0 ? nil : mode
    }

    public var isSymlink: Bool {
        guard let mode = unixMode else { return false }
        return (mode & 0xF000) == 0xA000 // S_IFLNK
    }
}

/// Little-endian binary reading/writing helpers over Data.
///
/// The readers are bounds-checked and throwing on purpose. Every offset
/// they are handed derives from a header field an attacker chose, and an
/// out-of-range `Data` subscript is a trap rather than an error — a crash
/// in the parser is a crash of the app that double-clicked the `.zip`.
/// Keeping the check inside the accessor means a read added later cannot
/// forget it; callers keep their own guards for the better message.
extension Data {
    func readU16(at offset: Int) throws -> UInt16 {
        // Phrased as a subtraction: `offset + 2` would itself overflow for
        // an offset near Int.max.
        guard offset >= 0, count - offset >= 2 else {
            throw ZipReaderError.corrupt("read of 2 bytes at \(offset) is out of bounds (\(count))")
        }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func readU32(at offset: Int) throws -> UInt32 {
        UInt32(try readU16(at: offset)) | UInt32(try readU16(at: offset + 2)) << 16
    }

    func readU64(at offset: Int) throws -> UInt64 {
        UInt64(try readU32(at: offset)) | UInt64(try readU32(at: offset + 4)) << 32
    }

    mutating func appendU16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendU32(_ v: UInt32) {
        appendU16(UInt16(v & 0xFFFF))
        appendU16(UInt16(v >> 16))
    }

    mutating func appendU64(_ v: UInt64) {
        appendU32(UInt32(v & 0xFFFF_FFFF))
        appendU32(UInt32(v >> 32))
    }
}
