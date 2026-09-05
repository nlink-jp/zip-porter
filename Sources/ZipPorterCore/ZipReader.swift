import Foundation

public enum ZipReaderError: Error, Equatable {
    case notAZipFile
    case corrupt(String)
    case unsupportedMethod(UInt16)
    case unsupportedFeature(String)
    case passwordRequired
    case wrongPassword
    case crcMismatch(entryName: String)
    case authenticationFailed(entryName: String)
    /// An entry produced more output than its header declared — a
    /// decompression bomb, caught mid-stream before the write completes
    /// (ADR-0001 §1).
    case sizeExceedsDeclared(entryName: String)
    /// Entry data ranges overlap: the `42.zip` construction, where many
    /// central-directory entries point at one compressed payload
    /// (ADR-0001 §3). Legitimate writers never produce this.
    case overlappingEntries
}

/// Random-access ZIP reader: parses the central directory eagerly, streams
/// entry data on demand. Sizes/CRC come from the central directory (the
/// authoritative copy); ZIP64 archives are supported.
public final class ZipReader {
    private let file: FileHandle
    private let fileSize: UInt64
    private static let chunkSize = 256 << 10

    public private(set) var entries: [ZipEntry] = []
    /// Encoding decided for entries that lack the UTF-8 flag.
    public private(set) var detectedEncoding: NameEncoding = .utf8

    public init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        fileSize = try file.seekToEnd()
        do {
            try parseCentralDirectory()
            try resolveEntryRanges()
        } catch {
            try? file.close()
            throw error
        }
        detectedEncoding = EncodingDetector.detect(
            entries.filter { !$0.flags.contains(.utf8Name) }.map(\.rawName))
    }

    /// Total uncompressed size the archive declares — the extraction
    /// budget checked against free space before writing (ADR-0001 §2).
    ///
    /// The sum saturates rather than wraps. Two ZIP64 entries declaring
    /// 2^63 each sum to exactly zero in wrapping arithmetic, which would
    /// hand the budget check a total of "nothing" and wave the archive
    /// through — the declaration is the only thing that check has to go on,
    /// so a total that cannot fit UInt64 has to read as "more than any
    /// volume holds", never as a small number.
    public var declaredTotalSize: UInt64 {
        entries.reduce(UInt64(0)) { total, entry in
            let (sum, overflowed) = total.addingReportingOverflow(entry.uncompressedSize)
            return overflowed ? .max : sum
        }
    }

    /// Resolve where each file entry's payload starts — from its *local*
    /// header, the copy extraction reads — and reject archives whose
    /// `[localHeaderOffset, payloadEnd)` ranges overlap or run past EOF
    /// (ADR-0001 §3, ADR-0005). This is the one derivation of the data
    /// offset: `extract` starts at the `dataOffset` stored here and reads no
    /// header of its own. Computing the range from the central directory's
    /// lengths instead let two local headers nest inside each other's extra
    /// field and pass. Entries are visited in offset order so the header
    /// reads are sequential.
    private func resolveEntryRanges() throws {
        let order = entries.indices
            .filter { !entries[$0].isDirectory }
            .sorted { entries[$0].localHeaderOffset < entries[$1].localHeaderOffset }
        // Small entries' local headers sit a few hundred bytes apart, so
        // they are read through a window: one 256 KiB read serves every
        // header inside it, and a hundred thousand tiny entries cost a few
        // hundred reads rather than a hundred thousand — a blink instead of
        // minutes on a network volume. Large entries fall back to one read
        // per header, but then there are few of them.
        var window = Data()
        var windowStart: UInt64 = 0
        func localHeader(at start: UInt64) throws -> Data {
            // `start + 30 <= fileSize` was checked by the caller.
            if start < windowStart || start + 30 > windowStart + UInt64(window.count) {
                windowStart = start
                window = try read(at: start, count: Int(min(UInt64(Self.chunkSize), fileSize - start)))
            }
            let offset = window.startIndex + Int(start - windowStart)
            return window.subdata(in: offset..<(offset + 30))
        }

        var previousEnd: UInt64 = 0
        for (rank, index) in order.enumerated() {
            let entry = entries[index]
            let start = entry.localHeaderOffset
            // Every bound is a subtraction from the known-good `fileSize`:
            // offset and lengths are attacker-chosen, and an addition inside
            // the check would be the overflow the check exists to catch.
            guard start <= fileSize, fileSize - start >= 30 else {
                throw ZipReaderError.corrupt("local header at \(start) past end of file")
            }
            let lh = try localHeader(at: start)
            guard try lh.readU32(at: 0) == Zip.localHeaderSignature else {
                throw ZipReaderError.corrupt("local header at \(start)")
            }
            let headerLength = 30 + UInt64(try lh.readU16(at: 26)) + UInt64(try lh.readU16(at: 28))
            guard headerLength <= fileSize - start else {
                throw ZipReaderError.corrupt("entry data runs past end of file")
            }
            let dataOffset = start + headerLength
            guard entry.compressedSize <= fileSize - dataOffset else {
                throw ZipReaderError.corrupt("entry data runs past end of file")
            }
            entries[index].dataOffset = dataOffset
            // Sorted by start and disjoint so far, so `previousEnd` is the
            // furthest byte any earlier entry reaches.
            if rank > 0, start < previousEnd {
                throw ZipReaderError.overlappingEntries
            }
            previousEnd = dataOffset + entry.compressedSize
        }
    }

    deinit { try? file.close() }

    /// Decoded entry name. The UTF-8 flag is authoritative when present;
    /// `forcedEncoding` overrides the detected encoding for unflagged entries.
    public func name(of entry: ZipEntry, forcedEncoding: NameEncoding? = nil) -> String {
        if entry.flags.contains(.utf8Name) {
            return EncodingDetector.decode(entry.rawName, as: .utf8)
        }
        return EncodingDetector.decode(entry.rawName, as: forcedEncoding ?? detectedEncoding)
    }

    // MARK: - Central directory

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        guard let d = try file.read(upToCount: count), d.count == count else {
            throw ZipReaderError.corrupt("truncated read at \(offset)")
        }
        return d
    }

    private func parseCentralDirectory() throws {
        guard fileSize >= 22 else { throw ZipReaderError.notAZipFile }
        // EOCD is in the last 22 bytes + up to 64 KiB of archive comment.
        let tailLen = Int(min(fileSize, UInt64(22 + 65_535)))
        let tailStart = fileSize - UInt64(tailLen)
        let tail = try read(at: tailStart, count: tailLen)

        var eocdPos: Int?
        var i = tailLen - 22
        while i >= 0 {
            if try tail.readU32(at: i) == Zip.eocdSignature {
                eocdPos = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdPos else { throw ZipReaderError.notAZipFile }

        var totalEntries = UInt64(try tail.readU16(at: eocd + 10))
        var cdSize = UInt64(try tail.readU32(at: eocd + 12))
        var cdOffset = UInt64(try tail.readU32(at: eocd + 16))

        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: locator sits immediately before the EOCD. A file whose
            // EOCD starts within 20 bytes of the front has nowhere to put
            // one — subtracting first would trap on UInt64 underflow.
            let eocdAbs = tailStart + UInt64(eocd)
            guard eocdAbs >= 20 else {
                throw ZipReaderError.corrupt("ZIP64 locator missing")
            }
            let locator = try read(at: eocdAbs - 20, count: 20)
            guard try locator.readU32(at: 0) == Zip.zip64LocatorSignature else {
                throw ZipReaderError.corrupt("ZIP64 locator missing")
            }
            let z64Offset = try locator.readU64(at: 8)
            let z64 = try read(at: z64Offset, count: 56)
            guard try z64.readU32(at: 0) == Zip.zip64EOCDSignature else {
                throw ZipReaderError.corrupt("ZIP64 EOCD missing")
            }
            totalEntries = try z64.readU64(at: 32)
            cdSize = try z64.readU64(at: 40)
            cdOffset = try z64.readU64(at: 48)
        }

        // 256 MiB ceiling: a million entries occupy roughly 100 MB of
        // central directory, so this stays far above real archives while
        // bounding the pre-extraction allocation (ADR-0001). The bounds are
        // phrased as subtractions from fileSize because a ZIP64 record can
        // declare values whose *sum* overflows UInt64 — computing
        // `cdOffset + cdSize` to check them would trap before the check runs.
        guard cdSize <= 256 << 20, cdOffset <= fileSize, cdSize <= fileSize - cdOffset else {
            throw ZipReaderError.corrupt("central directory out of bounds")
        }
        let cd = try read(at: cdOffset, count: Int(cdSize))

        var pos = 0
        entries.reserveCapacity(Int(min(totalEntries, 1 << 20)))
        for _ in 0..<totalEntries {
            guard pos + 46 <= cd.count, try cd.readU32(at: pos) == Zip.centralHeaderSignature else {
                throw ZipReaderError.corrupt("central header at \(pos)")
            }
            let versionMadeBy = try cd.readU16(at: pos + 4)
            let flags = Zip.Flags(rawValue: try cd.readU16(at: pos + 8))
            let methodRaw = try cd.readU16(at: pos + 10)
            let dosTime = try cd.readU16(at: pos + 12)
            let dosDate = try cd.readU16(at: pos + 14)
            let crc = try cd.readU32(at: pos + 16)
            var compSize = UInt64(try cd.readU32(at: pos + 20))
            var uncompSize = UInt64(try cd.readU32(at: pos + 24))
            let nameLen = Int(try cd.readU16(at: pos + 28))
            let extraLen = Int(try cd.readU16(at: pos + 30))
            let commentLen = Int(try cd.readU16(at: pos + 32))
            let externalAttr = try cd.readU32(at: pos + 38)
            var localOffset = UInt64(try cd.readU32(at: pos + 42))

            guard pos + 46 + nameLen + extraLen + commentLen <= cd.count else {
                throw ZipReaderError.corrupt("central entry overruns directory")
            }
            let rawName = cd.subdata(in: (cd.startIndex + pos + 46)..<(cd.startIndex + pos + 46 + nameLen))

            // Extra fields: ZIP64 sizes/offset and the WinZip AES descriptor.
            var aesInfo: (vendorVersion: UInt8, strength: Zip.AESStrength, actualMethod: UInt16)?
            var e = pos + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = try cd.readU16(at: e)
                let size = Int(try cd.readU16(at: e + 2))
                guard e + 4 + size <= extraEnd else { break }
                switch id {
                case Zip.ExtraID.zip64:
                    var f = e + 4
                    if uncompSize == 0xFFFF_FFFF, f + 8 <= e + 4 + size {
                        uncompSize = try cd.readU64(at: f); f += 8
                    }
                    if compSize == 0xFFFF_FFFF, f + 8 <= e + 4 + size {
                        compSize = try cd.readU64(at: f); f += 8
                    }
                    if localOffset == 0xFFFF_FFFF, f + 8 <= e + 4 + size {
                        localOffset = try cd.readU64(at: f); f += 8
                    }
                case Zip.ExtraID.aes where size >= 7:
                    let vendorVersion = UInt8(try cd.readU16(at: e + 4) & 0xFF)
                    let strengthRaw = cd[cd.startIndex + e + 8]
                    if let strength = Zip.AESStrength(rawValue: strengthRaw) {
                        aesInfo = (vendorVersion, strength, try cd.readU16(at: e + 9))
                    }
                default:
                    break
                }
                e += 4 + size
            }

            let method = Zip.Method(rawValue: methodRaw)
            var encryption: Zip.Encryption = .none
            if flags.contains(.encrypted) {
                if method == .aes {
                    guard let aes = aesInfo else {
                        throw ZipReaderError.corrupt("AES entry without 0x9901 extra field")
                    }
                    encryption = .aes(strength: aes.strength,
                                      vendorVersion: aes.vendorVersion,
                                      actualMethod: aes.actualMethod)
                } else {
                    encryption = .zipCrypto
                }
            }

            entries.append(ZipEntry(
                rawName: rawName,
                flags: flags,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: crc,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset,
                externalAttributes: externalAttr,
                versionMadeBy: versionMadeBy,
                encryption: encryption))

            pos += 46 + nameLen + extraLen + commentLen
        }
    }

    // MARK: - Extraction

    /// Stream-extract one entry; `sink` receives decompressed chunks.
    /// CRC and size are verified (except AE-2 entries, whose CRC is zeroed
    /// by spec — their HMAC covers integrity instead).
    public func extract(_ entry: ZipEntry,
                        password: String? = nil,
                        sink: (Data) throws -> Void) throws {
        if entry.isDirectory { return }

        let effectiveMethod: Zip.Method
        switch entry.encryption {
        case .aes(_, _, let actual):
            effectiveMethod = Zip.Method(rawValue: actual)
        default:
            effectiveMethod = entry.method
        }
        switch effectiveMethod {
        case .store, .deflate:
            break
        case .aes, .other:
            throw ZipReaderError.unsupportedMethod(effectiveMethod.rawValue)
        }

        // Where the payload starts was resolved from the local header at
        // open, together with the overlap/EOF check (`resolveEntryRanges`,
        // ADR-0005). Reading the header again here would be a second
        // derivation of the same fact — the gap the check used to have.
        var offset = entry.dataOffset
        var remaining = entry.compressedSize

        var decryptor: EntryDecryptor?
        switch entry.encryption {
        case .none:
            break
        case .zipCrypto:
            guard let password else { throw ZipReaderError.passwordRequired }
            let headerLen = UInt64(ZipCryptoCipher.headerSize)
            guard remaining >= headerLen else { throw ZipReaderError.corrupt("ZipCrypto data too short") }
            let header = try read(at: offset, count: ZipCryptoCipher.headerSize)
            // Bit 3 archives verify against the DOS time's high byte; others
            // against the CRC's high byte.
            let check: UInt8 = entry.flags.contains(.dataDescriptor)
                ? UInt8(entry.dosTime >> 8)
                : UInt8(entry.crc32 >> 24)
            guard var cipher = ZipCryptoCipher(password: password, header: header, checkByte: check) else {
                throw ZipReaderError.wrongPassword
            }
            offset += headerLen
            remaining -= headerLen
            decryptor = EntryDecryptor { cipher.decrypt($0) } finalize: { _ in }
        case .aes(let strength, _, _):
            guard let password else { throw ZipReaderError.passwordRequired }
            let overhead = UInt64(strength.saltBytes + 2 + WinZipAES.authCodeSize)
            guard remaining >= overhead else { throw ZipReaderError.corrupt("AES data too short") }
            let salt = try read(at: offset, count: strength.saltBytes)
            let verifier = try read(at: offset + UInt64(strength.saltBytes), count: 2)
            guard var aes = WinZipAES(password: password, strength: strength,
                                      salt: salt, passwordVerifier: verifier) else {
                throw ZipReaderError.wrongPassword
            }
            offset += UInt64(strength.saltBytes + 2)
            remaining -= overhead // trailing 10-byte auth code excluded from data
            let entryName = name(of: entry)
            decryptor = EntryDecryptor(trailerSize: WinZipAES.authCodeSize) {
                aes.process($0)
            } finalize: { trailer in
                guard aes.verifyAuthCode(trailer) else {
                    throw ZipReaderError.authenticationFailed(entryName: entryName)
                }
            }
        }

        var crc = CRC32()
        var outCount: UInt64 = 0
        let declaredSize = entry.uncompressedSize
        func out(_ d: Data) throws {
            // Fail-fast: stop the moment output exceeds what the header
            // declared, instead of writing an unbounded amount and only
            // then failing the size check (ADR-0001 §1).
            guard outCount &+ UInt64(d.count) <= declaredSize else {
                throw ZipReaderError.sizeExceedsDeclared(entryName: name(of: entry))
            }
            crc.update(d)
            outCount += UInt64(d.count)
            try sink(d)
        }

        let inflater = effectiveMethod == .deflate ? try DeflateStream(.decompress) : nil
        let payloadLength = remaining
        while remaining > 0 {
            let n = Int(min(remaining, UInt64(Self.chunkSize)))
            var chunk = try read(at: offset, count: n)
            offset += UInt64(n)
            remaining -= UInt64(n)
            if let decryptor { chunk = decryptor.process(chunk) }
            if let inflater {
                try inflater.process(chunk, final: remaining == 0, sink: out)
            } else {
                try out(chunk)
            }
        }
        if payloadLength == 0, let inflater {
            // Zero-length ciphertext/payload: the loop never ran, so the
            // inflater still needs its FINALIZE spin.
            try inflater.process(Data(), final: true, sink: out)
        }

        if let decryptor {
            let trailer = decryptor.trailerSize > 0
                ? try read(at: offset, count: decryptor.trailerSize)
                : Data()
            try decryptor.finalize(trailer)
        }

        guard outCount == entry.uncompressedSize else {
            throw ZipReaderError.corrupt("size mismatch for \(name(of: entry))")
        }
        // AE-2 zeroes the CRC field; the HMAC above already verified integrity.
        if case .aes(_, let vendorVersion, _) = entry.encryption, vendorVersion >= 2 {
            return
        }
        guard crc.value == entry.crc32 else {
            throw ZipReaderError.crcMismatch(entryName: name(of: entry))
        }
    }

    /// Extract one entry fully into memory.
    public func extractData(_ entry: ZipEntry, password: String? = nil) throws -> Data {
        var out = Data()
        try extract(entry, password: password) { out.append($0) }
        return out
    }
}

/// Streaming decrypt hook: transforms ciphertext chunks and, at the end,
/// checks the entry trailer (AES auth code; ZipCrypto has none).
struct EntryDecryptor {
    let process: (Data) -> Data
    let finalize: (Data) throws -> Void
    let trailerSize: Int

    init(trailerSize: Int = 0,
         _ process: @escaping (Data) -> Data,
         finalize: @escaping (Data) throws -> Void) {
        self.process = process
        self.finalize = finalize
        self.trailerSize = trailerSize
    }
}
