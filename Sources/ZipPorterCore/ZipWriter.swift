import Foundation
import Security

public enum ZipWriterError: Error, Equatable {
    case nameNotEncodable(String)
    /// The encoded name does not fit the format's 16-bit length field.
    case nameTooLong(String)
    case duplicateName(String)
    case randomFailure
    case ioError(String)
}

/// Streaming ZIP writer. Entry data is compressed (and optionally encrypted)
/// straight to the output file; CRC/size fields are patched back afterward,
/// so no data descriptors are emitted (best compatibility with old tools).
public final class ZipWriter {
    public enum NameEncoding: Sendable, Equatable {
        /// NFC UTF-8 with the UTF-8 flag (bit 11) on non-ASCII names.
        case utf8
        /// CP932 for legacy Japanese Windows tools; unmappable names error.
        case cp932
    }

    public enum Encryption: Sendable, Equatable {
        case none
        /// Explorer-compatible but weak; callers must warn.
        case zipCrypto(password: String)
        /// WinZip AE-2, AES-256.
        case aes256(password: String)
    }

    public struct Options: Sendable {
        public var nameEncoding: NameEncoding = .utf8
        public var encryption: Encryption = .none
        public init() {}
    }

    /// File extensions stored without deflate (already compressed).
    public static let storeExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif",
        "mp4", "mov", "m4v", "mp3", "m4a", "aac", "opus",
    ]

    /// Entries at least this large get ZIP64 local headers. Internal so
    /// tests can force the ZIP64 path with small data.
    var zip64Threshold: UInt64 = 0xFFFF_FF00

    private struct CentralRecord {
        var nameBytes: Data
        var flags: Zip.Flags
        var methodRaw: UInt16
        var dosTime: UInt16
        var dosDate: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
        var versionNeeded: UInt16
        var aesActualMethod: UInt16?
    }

    private let file: FileHandle
    private let options: Options
    private var records: [CentralRecord] = []
    private var seenNames: Set<Data> = []
    private var finalized = false
    private static let chunkSize = 256 << 10

    /// `url` must not exist: the archive is created exclusively, so a file
    /// that appears between the caller's name choice and this call fails the
    /// write instead of being truncated. `Packer` always writes to a fresh
    /// `.part` path and renames afterwards.
    public init(url: URL, options: Options = Options()) throws {
        do {
            file = try PathUtil.createExclusively(at: url)
        } catch {
            throw ZipWriterError.ioError("cannot create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        self.options = options
    }

    deinit { try? file.close() }

    // MARK: - Public API

    /// Add a directory entry (name will be given a trailing slash).
    public func addDirectory(_ name: String, modificationDate: Date = Date()) throws {
        let dirName = name.hasSuffix("/") ? name : name + "/"
        try addEntry(name: dirName, isDirectory: true, modificationDate: modificationDate,
                     size: 0, open: { { nil } })
    }

    public func addFile(_ name: String, data: Data, modificationDate: Date = Date()) throws {
        try addEntry(name: name, isDirectory: false, modificationDate: modificationDate,
                     size: UInt64(data.count), open: {
            var sent = false
            return {
                if sent { return nil }
                sent = true
                return data.isEmpty ? nil : data
            }
        })
    }

    /// Add a file from disk (streamed; the source may be read twice for
    /// ZipCrypto's CRC pre-pass). `forceStore` skips deflate for data a
    /// probe already found incompressible (ADR-0002).
    public func addFile(_ name: String, fileURL: URL,
                        modificationDate: Date? = nil,
                        forceStore: Bool = false,
                        onBytes: ((Int) -> Void)? = nil) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = modificationDate ?? (attrs[.modificationDate] as? Date) ?? Date()
        try addEntry(name: name, isDirectory: false, modificationDate: mtime,
                     size: size, forceStore: forceStore, onBytes: onBytes, open: {
            let fh = try FileHandle(forReadingFrom: fileURL)
            return {
                let chunk = try fh.read(upToCount: Self.chunkSize)
                if chunk == nil || chunk!.isEmpty {
                    try fh.close()
                    return nil
                }
                return chunk
            }
        })
    }

    /// Add an entry whose compressed bytes are supplied by the caller —
    /// the output of the parallel compressor. `next` yields those bytes.
    func addPrecompressed(_ name: String,
                          precompressed: Precompressed,
                          modificationDate: Date,
                          open: @escaping () throws -> (() throws -> Data?)) throws {
        try addEntry(name: name,
                     isDirectory: false,
                     modificationDate: modificationDate,
                     size: precompressed.uncompressedSize,
                     precompressed: precompressed,
                     open: open)
    }

    /// Write the central directory and end record. Must be called last.
    public func finalize() throws {
        precondition(!finalized, "finalize() called twice")
        finalized = true
        let cdOffset = try file.offset()

        var cd = Data()
        for r in records {
            let zip64 = r.localHeaderOffset >= 0xFFFF_FFFF
                || r.compressedSize >= 0xFFFF_FFFF
                || r.uncompressedSize >= 0xFFFF_FFFF
            var extra = Data()
            if zip64 {
                extra.appendU16(Zip.ExtraID.zip64)
                extra.appendU16(24)
                extra.appendU64(r.uncompressedSize)
                extra.appendU64(r.compressedSize)
                extra.appendU64(r.localHeaderOffset)
            }
            if let actual = r.aesActualMethod {
                extra.append(Self.aesExtraField(actualMethod: actual))
            }
            cd.appendU32(Zip.centralHeaderSignature)
            cd.appendU16(3 << 8 | 20) // made by: Unix, spec 2.0
            cd.appendU16(zip64 ? max(r.versionNeeded, 45) : r.versionNeeded)
            cd.appendU16(r.flags.rawValue)
            cd.appendU16(r.methodRaw)
            cd.appendU16(r.dosTime)
            cd.appendU16(r.dosDate)
            cd.appendU32(r.crc32)
            cd.appendU32(zip64 ? 0xFFFF_FFFF : UInt32(r.compressedSize))
            cd.appendU32(zip64 ? 0xFFFF_FFFF : UInt32(r.uncompressedSize))
            cd.appendU16(UInt16(r.nameBytes.count))
            cd.appendU16(UInt16(extra.count))
            cd.appendU16(0) // comment
            cd.appendU16(0) // disk start
            cd.appendU16(0) // internal attrs
            cd.appendU32(r.externalAttributes)
            cd.appendU32(zip64 ? 0xFFFF_FFFF : UInt32(r.localHeaderOffset))
            cd.append(r.nameBytes)
            cd.append(extra)
        }
        try file.write(contentsOf: cd)

        let cdSize = UInt64(cd.count)
        let needZip64EOCD = records.count >= 0xFFFF
            || cdOffset >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF

        if needZip64EOCD {
            let z64Offset = cdOffset + cdSize
            var z64 = Data()
            z64.appendU32(Zip.zip64EOCDSignature)
            z64.appendU64(44) // size of remainder
            z64.appendU16(3 << 8 | 45)
            z64.appendU16(45)
            z64.appendU32(0) // this disk
            z64.appendU32(0) // cd disk
            z64.appendU64(UInt64(records.count))
            z64.appendU64(UInt64(records.count))
            z64.appendU64(cdSize)
            z64.appendU64(cdOffset)
            var locator = Data()
            locator.appendU32(Zip.zip64LocatorSignature)
            locator.appendU32(0)
            locator.appendU64(z64Offset)
            locator.appendU32(1)
            try file.write(contentsOf: z64 + locator)
        }

        var eocd = Data()
        eocd.appendU32(Zip.eocdSignature)
        eocd.appendU16(0)
        eocd.appendU16(0)
        eocd.appendU16(UInt16(min(records.count, 0xFFFF)))
        eocd.appendU16(UInt16(min(records.count, 0xFFFF)))
        eocd.appendU32(cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize))
        eocd.appendU32(cdOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdOffset))
        eocd.appendU16(0)
        try file.write(contentsOf: eocd)
        try file.close()
    }

    // MARK: - Entry writing

    private func encodeName(_ name: String) throws -> (bytes: Data, flags: Zip.Flags) {
        let nfc = FileNameTransform.nfc(name)
        switch options.nameEncoding {
        case .utf8:
            let bytes = Data(nfc.utf8)
            let isASCII = bytes.allSatisfy { $0 < 0x80 }
            return (bytes, isASCII ? [] : [.utf8Name])
        case .cp932:
            guard let bytes = FileNameTransform.encodeCP932(nfc) else {
                throw ZipWriterError.nameNotEncodable(name)
            }
            return (bytes, [])
        }
    }

    private static func aesExtraField(actualMethod: UInt16) -> Data {
        var extra = Data()
        extra.appendU16(Zip.ExtraID.aes)
        extra.appendU16(7)
        extra.appendU16(2) // AE-2
        extra.append(contentsOf: [UInt8(ascii: "A"), UInt8(ascii: "E")])
        extra.append(Zip.AESStrength.aes256.rawValue)
        extra.appendU16(actualMethod)
        return extra
    }

    private static func randomData(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ZipWriterError.randomFailure
        }
        return Data(bytes)
    }

    /// An entry whose bytes were already compressed elsewhere — by the
    /// parallel compressor (ADR-0002). The writer then only has to encrypt
    /// and frame them.
    struct Precompressed {
        var method: Zip.Method
        var crc32: UInt32
        var uncompressedSize: UInt64
    }

    /// `open` returns a fresh chunk iterator over the source (re-openable —
    /// ZipCrypto needs a CRC pre-pass over the plaintext). With
    /// `precompressed`, the iterator yields compressed bytes instead and
    /// the sizes/CRC come from the caller.
    private func addEntry(name: String,
                          isDirectory: Bool,
                          modificationDate: Date,
                          size: UInt64,
                          precompressed: Precompressed? = nil,
                          forceStore: Bool = false,
                          onBytes: ((Int) -> Void)? = nil,
                          open: () throws -> (() throws -> Data?)) throws {
        precondition(!finalized, "addEntry after finalize()")
        let (nameBytes, nameFlags) = try encodeName(name)
        // The name length is a 16-bit field in both headers; converting an
        // over-long name would trap rather than write a broken archive.
        guard nameBytes.count <= 0xFFFF else {
            throw ZipWriterError.nameTooLong(name)
        }
        guard seenNames.insert(nameBytes).inserted else {
            throw ZipWriterError.duplicateName(name)
        }

        let (dosDate, dosTime) = DOSDateTime.from(modificationDate)
        let ext = (name as NSString).pathExtension.lowercased()
        let baseMethod: Zip.Method = precompressed?.method
            ?? ((isDirectory || size == 0 || forceStore || Self.storeExtensions.contains(ext))
                ? .store : .deflate)

        var flags = nameFlags
        var methodRaw = baseMethod.rawValue
        var versionNeeded: UInt16 = 20
        var aesActualMethod: UInt16?
        let encryption: Encryption = isDirectory ? .none : options.encryption
        switch encryption {
        case .none:
            break
        case .zipCrypto:
            flags.insert(.encrypted)
        case .aes256:
            flags.insert(.encrypted)
            aesActualMethod = baseMethod.rawValue
            methodRaw = Zip.Method.aes.rawValue
            versionNeeded = 51
        }

        // ZipCrypto's check byte needs the plaintext CRC before any data is
        // written — pre-scan the source.
        var precomputedCRC: UInt32 = 0
        if case .zipCrypto = encryption {
            if let precompressed {
                precomputedCRC = precompressed.crc32
            } else {
                var crc = CRC32()
                let next = try open()
                while let chunk = try next() { crc.update(chunk) }
                precomputedCRC = crc.value
            }
        }

        let zip64 = size >= zip64Threshold
        var localExtra = Data()
        if zip64 {
            localExtra.appendU16(Zip.ExtraID.zip64)
            localExtra.appendU16(16)
            localExtra.appendU64(0) // uncompressed — patched
            localExtra.appendU64(0) // compressed — patched
        }
        if let actual = aesActualMethod {
            localExtra.append(Self.aesExtraField(actualMethod: actual))
        }

        let headerOffset = try file.offset()
        var header = Data()
        header.appendU32(Zip.localHeaderSignature)
        header.appendU16(zip64 ? max(versionNeeded, 45) : versionNeeded)
        header.appendU16(flags.rawValue)
        header.appendU16(methodRaw)
        header.appendU16(dosTime)
        header.appendU16(dosDate)
        header.appendU32(precomputedCRC) // 0 unless ZipCrypto; patched later
        header.appendU32(zip64 ? 0xFFFF_FFFF : 0) // compressed — patched
        header.appendU32(zip64 ? 0xFFFF_FFFF : 0) // uncompressed — patched
        header.appendU16(UInt16(nameBytes.count))
        header.appendU16(UInt16(localExtra.count))
        try file.write(contentsOf: header + nameBytes + localExtra)

        // --- data pipeline: source → [deflate] → [encrypt] → file ---------
        var crc = CRC32()
        var uncompressed: UInt64 = 0
        var written: UInt64 = 0

        var zipCryptoCipher: ZipCryptoCipher?
        var aes: WinZipAES?
        switch encryption {
        case .none:
            break
        case .zipCrypto(let password):
            var headerBytes = Data()
            let cipher = ZipCryptoCipher(
                password: password,
                randomBytes: try Self.randomData(ZipCryptoCipher.headerSize - 1),
                checkByte: UInt8(precomputedCRC >> 24),
                header: &headerBytes)
            zipCryptoCipher = cipher
            try file.write(contentsOf: headerBytes)
            written += UInt64(headerBytes.count)
        case .aes256(let password):
            let salt = try Self.randomData(Zip.AESStrength.aes256.saltBytes)
            let cipher = WinZipAES(encryptWith: password, strength: .aes256, salt: salt)
            aes = cipher
            try file.write(contentsOf: salt + cipher.derivedVerifier)
            written += UInt64(salt.count + 2)
        }

        func emit(_ d: Data) throws {
            var out = d
            if zipCryptoCipher != nil { out = zipCryptoCipher!.encrypt(out) }
            if aes != nil { out = aes!.process(out) }
            written += UInt64(out.count)
            try file.write(contentsOf: out)
        }

        let deflater = (precompressed == nil && baseMethod == .deflate)
            ? try ZlibDeflateStream() : nil
        let next = try open()
        while let chunk = try next() {
            if precompressed == nil {
                crc.update(chunk)
                uncompressed += UInt64(chunk.count)
                onBytes?(chunk.count)
            }
            if let deflater {
                try deflater.process(chunk, final: false, sink: emit)
            } else {
                try emit(chunk)
            }
        }
        if let deflater {
            try deflater.process(Data(), final: true, sink: emit)
        }
        if let precompressed {
            uncompressed = precompressed.uncompressedSize
        }
        if aes != nil {
            let auth = aes!.authCode()
            try file.write(contentsOf: auth)
            written += UInt64(auth.count)
        }

        // --- patch the local header ---------------------------------------
        let crcValue: UInt32
        switch encryption {
        case .none: crcValue = precompressed?.crc32 ?? crc.value
        case .zipCrypto: crcValue = precomputedCRC
        case .aes256: crcValue = 0 // AE-2 zeroes the CRC
        }
        let end = try file.offset()
        try file.seek(toOffset: headerOffset + 14)
        var patch = Data()
        patch.appendU32(crcValue)
        if !zip64 {
            // The ZIP64 decision was made from the size the file reported
            // before we read it. A source that grew past 4 GiB in between
            // has no reserved extra field to patch, so say so instead of
            // trapping on the conversion or writing a truncated size.
            guard written <= 0xFFFF_FFFF, uncompressed <= 0xFFFF_FFFF else {
                throw ZipWriterError.ioError("'\(name)' grew past 4 GiB while it was being packed")
            }
            patch.appendU32(UInt32(written))
            patch.appendU32(UInt32(uncompressed))
            try file.write(contentsOf: patch)
        } else {
            try file.write(contentsOf: patch)
            // sizes stay 0xFFFFFFFF; real values live in the zip64 extra.
            let extraPos = headerOffset + 30 + UInt64(nameBytes.count) + 4
            try file.seek(toOffset: extraPos)
            var sizes = Data()
            sizes.appendU64(uncompressed)
            sizes.appendU64(written)
            try file.write(contentsOf: sizes)
        }
        try file.seek(toOffset: end)

        records.append(CentralRecord(
            nameBytes: nameBytes,
            flags: flags,
            methodRaw: methodRaw,
            dosTime: dosTime,
            dosDate: dosDate,
            crc32: crcValue,
            compressedSize: written,
            uncompressedSize: uncompressed,
            localHeaderOffset: headerOffset,
            externalAttributes: isDirectory
                ? (UInt32(0o40755) << 16) | 0x10
                : (UInt32(0o100644) << 16) | 0x20,
            versionNeeded: versionNeeded,
            aesActualMethod: aesActualMethod))
    }
}
