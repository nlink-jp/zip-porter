import CZlib
import XCTest
@testable import ZipPorterCore

/// Deflate64 decoding (ADR-0006), checked three ways: 7-Zip Deflate64
/// fixtures, zlib's Deflate output through the `.deflate` variant, and
/// hand-built streams for the Deflate64-only codes and every rejection rule.
final class Inflate64Tests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "testdata"))
    }

    private func entry(_ reader: ZipReader, _ name: String) throws -> ZipEntry {
        let want = name.precomposedStringWithCanonicalMapping
        return try XCTUnwrap(reader.entries.first {
            reader.name(of: $0).precomposedStringWithCanonicalMapping == want
        }, "entry \(name) not found")
    }

    /// Decode `stream`, handing it over `chunk` bytes at a time so chunk
    /// boundaries fall everywhere a test wants them to.
    private func inflate(_ variant: Inflate64.Variant, _ stream: Data,
                         chunk: Int = 4096) throws -> (output: Data, stats: Inflate64.Statistics) {
        let stream = Data(stream)
        var offset = 0
        var output = Data()
        let stats = try Inflate64.decode(variant, input: {
            guard offset < stream.count else { return nil }
            let end = min(offset + chunk, stream.count)
            defer { offset = end }
            return stream.subdata(in: offset..<end)
        }, sink: { output.append($0) })
        return (output, stats)
    }

    private func assertFails(_ variant: Inflate64.Variant, _ stream: Data,
                             _ expected: Inflate64.Failure,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try inflate(variant, stream), file: file, line: line) { error in
            XCTAssertEqual(error as? Inflate64.Failure, expected, file: file, line: line)
        }
    }

    // What gen-fixtures.sh put in the Deflate64 fixtures.
    private let fixtureBlock = 40960
    private var fixtureText: Data {
        Data((1...400).map { "\($0) 行目: 売上データの集計結果\n" }.joined().utf8)
    }

    private func assertLongMatch(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(data.count, fixtureBlock * 4, file: file, line: line)
        guard data.count == fixtureBlock * 4 else { return }
        let first = data.subdata(in: 0..<fixtureBlock)
        for k in 1..<4 {
            XCTAssertEqual(data.subdata(in: k * fixtureBlock..<(k + 1) * fixtureBlock), first,
                           "repeat \(k)", file: file, line: line)
        }
    }

    // MARK: - 7-Zip fixtures

    func testSevenZipDeflate64FixtureExtracts() throws {
        let reader = try ZipReader(url: try fixture("sevenzip-deflate64"))
        let long = try entry(reader, "long-match.bin")
        let text = try entry(reader, "text.txt")
        XCTAssertEqual(long.method, .deflate64)
        XCTAssertEqual(text.method, .deflate64)
        // extract verifies size and CRC against 7-Zip's central directory.
        assertLongMatch(try reader.extractData(long))
        XCTAssertEqual(try reader.extractData(text), fixtureText)
        XCTAssertEqual(try reader.extractData(try entry(reader, "日本語ファイル.txt")),
                       Data("こんにちは Windows\n".utf8))
    }

    /// The fixture is only worth having if it reaches the codes Deflate
    /// lacks; count them instead of trusting how the data was built.
    ///
    /// Only the far distances: 7-Zip's Deflate64 encoder never emits length
    /// code 285 (measured — 0 of them here, though the repeats run for
    /// 40 KiB), so the 16-extra-bit length is covered by the hand-built
    /// streams below, not by this fixture.
    func testSevenZipFixtureExercisesTheFarDistances() throws {
        let url = try fixture("sevenzip-deflate64")
        let reader = try ZipReader(url: url)
        let long = try entry(reader, "long-match.bin")
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: long.dataOffset)
        let payload = try XCTUnwrap(try file.read(upToCount: Int(long.compressedSize)))

        let (output, stats) = try inflate(.deflate64, payload)
        assertLongMatch(output)
        XCTAssertGreaterThan(stats.longDistances, 0, "no distance code 30/31 decoded")
    }

    func testSevenZipDeflate64InsideAES256Extracts() throws {
        let reader = try ZipReader(url: try fixture("sevenzip-deflate64-aes256"))
        let long = try entry(reader, "long-match.bin")
        guard case .aes(_, _, let actual) = long.encryption else {
            return XCTFail("expected an AES entry, got \(long.encryption)")
        }
        XCTAssertEqual(actual, 9)
        // The HMAC check after the stream needs the payload read to its end.
        assertLongMatch(try reader.extractData(long, password: "s3cret-pass"))
        XCTAssertEqual(try reader.extractData(try entry(reader, "text.txt"), password: "s3cret-pass"),
                       fixtureText)
        XCTAssertThrowsError(try reader.extractData(long, password: "wrong")) { error in
            XCTAssertEqual(error as? ZipReaderError, .wrongPassword)
        }
    }

    // MARK: - Deflate variant against zlib

    private func zlibRaw(_ input: Data, level: Int32, strategy: Int32) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, strategy, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw XCTSkip("zlib init failed")
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        let status: Int32 = input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                stream.next_in = UnsafeMutablePointer(mutating: inRaw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outRaw.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(outRaw.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return output.prefix(output.count - Int(stream.avail_out))
    }

    /// Stored, fixed, dynamic and Huffman-only blocks, outputs that cross
    /// the staging flush and history compaction many times, and input
    /// chunk boundaries at every bit position.
    func testDeflateVariantMatchesZlib() throws {
        var mixed = Data()
        for i in 0..<6 {
            mixed.append(TestSupport.noise(70_000, seed: UInt64(i)))
            mixed.append(TestSupport.symbols(90_000, seed: UInt64(i)))
        }
        let inputs: [(String, Data)] = [
            ("empty", Data()),
            ("one byte", Data("a".utf8)),
            ("text", Data(String(repeating: "売上データの集計 ", count: 3_000).utf8)),
            ("noise", TestSupport.noise(100_000, seed: 7)),
            ("mixed ~1 MB", mixed),
        ]
        let configs: [(String, Int32, Int32)] = [
            ("stored", 0, Z_DEFAULT_STRATEGY),
            ("level 1", 1, Z_DEFAULT_STRATEGY),
            ("level 9", 9, Z_DEFAULT_STRATEGY),
            ("fixed", 6, Z_FIXED),
            ("huffman only", 6, Z_HUFFMAN_ONLY),
            ("rle", 6, Z_RLE),
        ]
        for (inputName, input) in inputs {
            for (configName, level, strategy) in configs {
                let stream = try zlibRaw(input, level: level, strategy: strategy)
                for chunk in input.count <= 60_000 ? [1, 7, 65_536] : [7, 65_536] {
                    let (output, stats) = try inflate(.deflate, stream, chunk: chunk)
                    XCTAssertEqual(output, input, "\(inputName) / \(configName) / chunk \(chunk)")
                    XCTAssertEqual(stats.longDistances + stats.longLengths, 0)
                }
            }
        }
    }

    // MARK: - Deflate64-only codes, hand-built

    func testLengthCode285CarriesSixteenExtraBitsInDeflate64() throws {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(97)            // "a"
        w.fixedLiteralLength(285)
        w.put(65_535, 16)                  // 3 + 65535 = 65538
        w.fixedDistance(0)                 // distance 1
        w.fixedLiteralLength(256)
        let (output, stats) = try inflate(.deflate64, w.data)
        XCTAssertEqual(output, Data(repeating: 97, count: 65_539))
        XCTAssertEqual(stats.longLengths, 1)
    }

    func testLengthCode285IsAFixed258InDeflate() throws {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(97)
        w.fixedLiteralLength(285)          // no extra bits in Deflate
        w.fixedDistance(0)
        w.fixedLiteralLength(256)
        XCTAssertEqual(try inflate(.deflate, w.data).output, Data(repeating: 97, count: 259))
    }

    /// One block can expand without limit; the decoder must hand it over in
    /// bounded pieces — at most its buffer: the 64 KiB window, 256 KiB of
    /// staging and one symbol — or it writes past that buffer. Long matches
    /// and a long literal run.
    func testOneLargeBlockArrivesInBoundedPieces() throws {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(97)
        for _ in 0..<20 {
            w.fixedLiteralLength(285)
            w.put(65_535, 16)
            w.fixedDistance(0)
        }
        let literals = TestSupport.symbols(400_000, seed: 3)
        for byte in literals { w.fixedLiteralLength(Int(byte)) }
        w.fixedLiteralLength(256)
        let expected = Data(repeating: 97, count: 1 + 20 * 65_538) + literals

        let stream = w.data
        var offset = 0
        var pieces: [Int] = []
        var output = Data()
        try Inflate64.decode(.deflate64, input: {
            guard offset < stream.count else { return nil }
            let end = min(offset + 65_536, stream.count)
            defer { offset = end }
            return stream.subdata(in: offset..<end)
        }, sink: { pieces.append($0.count); output.append($0) })
        XCTAssertEqual(output, expected)
        XCTAssertGreaterThan(pieces.count, 4)
        XCTAssertLessThanOrEqual(pieces.max() ?? 0, (64 << 10) + (256 << 10) + 65_538)
    }

    /// 400 000 stored bytes push the output past the staging flush, so the
    /// matches that follow read history that has been compacted.
    private func farMatchStream() -> (stream: Data, expected: Data) {
        let history = TestSupport.noise(400_000, seed: 64)
        var w = BitWriter()
        var start = 0
        while start < history.count {
            let end = min(start + 65_535, history.count)
            w.stored(history.subdata(in: start..<end), final: false)
            start = end
        }
        var expected = history
        func copy(_ length: Int, back: Int) {
            for _ in 0..<length { expected.append(expected[expected.count - back]) }
        }
        w.fixedHeader(final: true)
        w.fixedLiteralLength(265)          // length 11 (+1 extra bit)
        w.put(0, 1)
        w.fixedDistance(31)                // 49153 + 16383 = 65536, the maximum
        w.put(16_383, 14)
        copy(11, back: 65_536)
        w.fixedLiteralLength(257)          // length 3
        w.fixedDistance(30)                // 32769
        w.put(0, 14)
        copy(3, back: 32_769)
        w.fixedLiteralLength(256)
        return (w.data, expected)
    }

    func testDistanceCodes30And31ReachBack64KInDeflate64() throws {
        let (stream, expected) = farMatchStream()
        for chunk in [7, 65_536] {
            let (output, stats) = try inflate(.deflate64, stream, chunk: chunk)
            XCTAssertEqual(output, expected, "chunk \(chunk)")
            XCTAssertEqual(stats.longDistances, 2)
        }
    }

    func testDistanceCodes30And31AreInvalidInDeflate() {
        assertFails(.deflate, farMatchStream().stream, .invalid("invalid distance symbol 31"))
    }

    // MARK: - Malformed streams

    func testRejectsTruncatedStreams() {
        assertFails(.deflate64, Data(), .truncated)

        var stored = BitWriter()
        stored.put(1, 1); stored.put(0, 2); stored.align()
        stored.put(10, 16); stored.put(10 ^ 0xFFFF, 16)
        stored.put(0x41, 8); stored.put(0x42, 8); stored.put(0x43, 8)
        assertFails(.deflate64, stored.data, .truncated)

        // A complete non-final block, then nothing.
        var nonFinal = BitWriter()
        nonFinal.fixedHeader(final: false)
        nonFinal.fixedLiteralLength(256)
        assertFails(.deflate64, nonFinal.data, .truncated)
    }

    func testRejectsReservedBlockType() {
        var w = BitWriter()
        w.put(1, 1); w.put(3, 2)
        assertFails(.deflate64, w.data, .invalid("reserved block type"))
    }

    func testRejectsStoredLengthMismatch() {
        var w = BitWriter()
        w.put(1, 1); w.put(0, 2); w.align()
        w.put(5, 16); w.put(5, 16)
        assertFails(.deflate64, w.data, .invalid("stored block length check failed"))
    }

    func testRejectsDistanceBeforeStartOfOutput() {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(257)
        w.fixedDistance(0)
        w.fixedLiteralLength(256)
        assertFails(.deflate64, w.data, .invalid("distance reaches before the start of output"))
    }

    func testRejectsLengthSymbols286And287() {
        for symbol in [286, 287] {
            var w = BitWriter()
            w.fixedHeader(final: true)
            w.fixedLiteralLength(symbol)
            assertFails(.deflate64, w.data, .invalid("invalid length symbol \(symbol)"))
        }
    }

    /// Dynamic header with HCLEN = 4: lengths for code-length symbols
    /// 16, 17, 18, 0 (the first four in transmission order).
    private func dynamicHeader(_ w: inout BitWriter, literals: Int = 257, distances: Int = 1,
                               codeLengthLengths: [Int]) {
        w.put(1, 1); w.put(2, 2)
        w.put(literals - 257, 5)
        w.put(distances - 1, 5)
        w.put(codeLengthLengths.count - 4, 4)
        for length in codeLengthLengths { w.put(length, 3) }
    }

    func testRejectsOverSubscribedCodeLengthCode() {
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: [1, 1, 1, 1])
        assertFails(.deflate64, w.data, .invalid("over-subscribed Huffman code"))
    }

    func testRejectsRepeatWithNoPreviousLength() {
        // Symbols 16 and 0 at one bit each: 0 → "0", 16 → "1".
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: [1, 0, 0, 1])
        w.code(1, 1)
        w.put(0, 2)
        assertFails(.deflate64, w.data, .invalid("repeat with no previous length"))
    }

    func testRejectsLiteralCodeWithoutEndOfBlock() {
        // Symbols 18 and 0: 0 → "0", 18 → "1". 138 + 120 zeros fill all 258.
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: [0, 0, 1, 1])
        w.code(1, 1); w.put(127, 7)
        w.code(1, 1); w.put(109, 7)
        assertFails(.deflate64, w.data, .invalid("no end-of-block code"))
    }

    func testRejectsCodeLengthsOverrun() {
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: [0, 0, 1, 1])
        w.code(1, 1); w.put(127, 7)
        w.code(1, 1); w.put(127, 7)        // 276 > 258
        assertFails(.deflate64, w.data, .invalid("code lengths overrun"))
    }

    func testRejectsIncompleteLiteralCode() {
        // Code-length code: 0 → "0", 2 → "10", 18 → "11" (HCLEN = 16 to
        // reach symbol 2, the 16th in transmission order).
        var lengths = [Int](repeating: 0, count: 16)
        lengths[2] = 2   // 18
        lengths[3] = 1   // 0
        lengths[15] = 2  // 2
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: lengths)
        w.code(0b11, 2); w.put(127, 7)     // 138 zeros
        w.code(0b11, 2); w.put(107, 7)     // 118 zeros → 256
        w.code(0b10, 2)                    // end-of-block gets length 2, alone
        w.code(0, 1)                       // the one distance length: 0
        assertFails(.deflate64, w.data, .invalid("incomplete Huffman code"))
    }

    // The two incomplete codes zlib accepts (and RFC 1951 §3.2.7 allows):
    // no distance codes at all, and a single one-bit distance code.

    func testAcceptsALiteralOnlyBlockWithNoDistanceCodes() throws {
        // Code-length code in transmission order up to symbol 1 (HCLEN 18):
        // 18 → "0", 0 → "10", 1 → "11".
        var cl = [Int](repeating: 0, count: 18)
        cl[2] = 1; cl[3] = 2; cl[17] = 2
        var w = BitWriter()
        dynamicHeader(&w, codeLengthLengths: cl)
        w.code(0, 1); w.put(86, 7)          // 97 zeros
        w.code(0b11, 2)                      // "a": length 1
        w.code(0, 1); w.put(127, 7)         // 138 zeros
        w.code(0, 1); w.put(9, 7)           // 20 zeros → index 256
        w.code(0b11, 2)                      // end-of-block: length 1
        w.code(0b10, 2)                      // the only distance length: 0
        for _ in 0..<3 { w.code(0, 1) }      // "a" → "0"
        w.code(1, 1)                         // end-of-block → "1"
        for variant in [Inflate64.Variant.deflate, .deflate64] {
            XCTAssertEqual(try inflate(variant, w.data).output, Data("aaa".utf8))
        }
    }

    func testAcceptsASingleOneBitDistanceCode() throws {
        // 18 → "0", 0 → "10", 1 → "110", 2 → "111".
        var cl = [Int](repeating: 0, count: 18)
        cl[2] = 1; cl[3] = 2; cl[15] = 3; cl[17] = 3
        var w = BitWriter()
        dynamicHeader(&w, literals: 258, codeLengthLengths: cl)
        w.code(0, 1); w.put(86, 7)          // 97 zeros
        w.code(0b110, 3)                     // "a": length 1
        w.code(0, 1); w.put(127, 7)
        w.code(0, 1); w.put(9, 7)           // → index 256
        w.code(0b111, 3)                     // end-of-block: length 2
        w.code(0b111, 3)                     // 257 (length 3): length 2
        w.code(0b110, 3)                     // distance code 0: length 1, alone
        w.code(0, 1)                         // "a"
        w.code(0b11, 2)                      // length 3
        w.code(0, 1)                         // distance 1
        w.code(0b10, 2)                      // end-of-block
        for variant in [Inflate64.Variant.deflate, .deflate64] {
            XCTAssertEqual(try inflate(variant, w.data).output, Data("aaaa".utf8))
        }
    }

    func testRejectsTooManyDistanceCodes() {
        var w = BitWriter()
        dynamicHeader(&w, distances: 32, codeLengthLengths: [0, 0, 1, 1])
        assertFails(.deflate, w.data, .invalid("too many distance codes"))
    }

    // MARK: - Through ZipReader

    /// One entry with the given method, flags, extra field and raw payload.
    private func rawZip(method: UInt16, payload: Data, uncompressedSize: UInt32,
                        crc: UInt32 = 0, flags: UInt16 = 0, extra: Data = Data()) throws -> URL {
        let name = Data("a.bin".utf8)
        var local = Data()
        local.appendU32(Zip.localHeaderSignature)
        for v: UInt16 in [20, flags, method, 0, 0] { local.appendU16(v) }
        local.appendU32(crc)
        local.appendU32(UInt32(payload.count))
        local.appendU32(uncompressedSize)
        local.appendU16(UInt16(name.count))
        local.appendU16(UInt16(extra.count))
        local.append(name)
        local.append(extra)
        var central = Data()
        central.appendU32(Zip.centralHeaderSignature)
        for v: UInt16 in [20, 20, flags, method, 0, 0] { central.appendU16(v) }
        central.appendU32(crc)
        central.appendU32(UInt32(payload.count))
        central.appendU32(uncompressedSize)
        for v: UInt16 in [UInt16(name.count), UInt16(extra.count), 0, 0, 0] { central.appendU16(v) }
        central.appendU32(0)
        central.appendU32(0)
        central.append(name)
        central.append(extra)
        var eocd = Data()
        eocd.appendU32(Zip.eocdSignature)
        for v: UInt16 in [0, 0, 1, 1] { eocd.appendU16(v) }
        eocd.appendU32(UInt32(central.count))
        eocd.appendU32(UInt32(local.count + payload.count))
        eocd.appendU16(0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inflate64-\(UUID().uuidString).zip")
        try (local + payload + central + eocd).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testOutputBeyondTheDeclaredSizeStopsAsABomb() throws {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(97)
        w.fixedLiteralLength(285)
        w.put(65_535, 16)
        w.fixedDistance(0)
        w.fixedLiteralLength(256)
        let reader = try ZipReader(url: try rawZip(method: 9, payload: w.data, uncompressedSize: 1_000))
        XCTAssertThrowsError(try reader.extractData(reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipReaderError, .sizeExceedsDeclared(entryName: "a.bin"))
        }
    }

    /// The stream ends in the first 256 KiB read and 300 000 bytes follow
    /// it inside the payload. The reader must read them anyway: the AES
    /// trailer sits after them and the HMAC covers them.
    func testPayloadAfterTheFinalBlockIsReadThroughForTheAESTrailer() throws {
        var w = BitWriter()
        w.fixedHeader(final: true)
        w.fixedLiteralLength(97)
        w.fixedLiteralLength(285)
        w.put(65_535, 16)
        w.fixedDistance(0)
        w.fixedLiteralLength(256)
        let plaintext = w.data + TestSupport.noise(300_000, seed: 9)
        let expected = Data(repeating: 97, count: 65_539)

        let salt = Data((0..<Zip.AESStrength.aes256.saltBytes).map { UInt8($0) })
        var aes = WinZipAES(encryptWith: "pw", strength: .aes256, salt: salt)
        let ciphertext = aes.process(plaintext)
        let payload = salt + aes.derivedVerifier + ciphertext + aes.authCode()
        var extra = Data()
        extra.appendU16(Zip.ExtraID.aes)
        extra.appendU16(7)
        extra.appendU16(2)                   // AE-2: CRC zeroed, HMAC checked
        extra.append(contentsOf: Array("AE".utf8))
        extra.append(Zip.AESStrength.aes256.rawValue)
        extra.appendU16(9)                   // the method inside: Deflate64

        let reader = try ZipReader(url: try rawZip(method: 99, payload: payload,
                                                   uncompressedSize: UInt32(expected.count),
                                                   flags: Zip.Flags.encrypted.rawValue, extra: extra))
        XCTAssertEqual(try reader.extractData(reader.entries[0], password: "pw"), expected)
    }

    func testMalformedDeflate64EntryIsRefusedAsCorrupt() throws {
        var w = BitWriter()
        w.put(1, 1); w.put(3, 2)
        let reader = try ZipReader(url: try rawZip(method: 9, payload: w.data, uncompressedSize: 10))
        XCTAssertThrowsError(try reader.extractData(reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipReaderError,
                           .entryCorrupt(entryName: "a.bin", detail: "Deflate64 reserved block type"))
        }
    }

    func testOtherMethodsRemainUnsupported() throws {
        let reader = try ZipReader(url: try rawZip(method: 12, payload: Data([1, 2, 3]), uncompressedSize: 3))
        XCTAssertThrowsError(try reader.extractData(reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipReaderError, .unsupportedMethod(12))
        }
    }
}

/// LSB-first bit packing as RFC 1951 §3.1.1 lays it out; Huffman codes go
/// in most-significant bit first.
private struct BitWriter {
    private var bytes: [UInt8] = []
    private var buffer: UInt64 = 0
    private var count = 0

    mutating func put(_ value: Int, _ bits: Int) {
        buffer |= UInt64(value) << UInt64(count)
        count += bits
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: buffer))
            buffer >>= 8
            count -= 8
        }
    }

    mutating func code(_ code: Int, _ bits: Int) {
        var reversed = 0
        for bit in 0..<bits where code & (1 << bit) != 0 { reversed |= 1 << (bits - 1 - bit) }
        put(reversed, bits)
    }

    mutating func align() {
        if count > 0 { put(0, 8 - count) }
    }

    mutating func fixedHeader(final: Bool) {
        put(final ? 1 : 0, 1)
        put(1, 2)
    }

    mutating func fixedLiteralLength(_ symbol: Int) {
        switch symbol {
        case 0...143: code(0x30 + symbol, 8)
        case 144...255: code(0x190 + symbol - 144, 9)
        case 256...279: code(symbol - 256, 7)
        default: code(0xC0 + symbol - 280, 8)
        }
    }

    mutating func fixedDistance(_ symbol: Int) { code(symbol, 5) }

    mutating func stored(_ payload: Data, final: Bool) {
        put(final ? 1 : 0, 1)
        put(0, 2)
        align()
        put(payload.count, 16)
        put(payload.count ^ 0xFFFF, 16)
        bytes.append(contentsOf: payload)
    }

    var data: Data {
        var copy = self
        copy.align()
        return Data(copy.bytes)
    }
}
