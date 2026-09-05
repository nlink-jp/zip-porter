import XCTest
@testable import ZipPorterCore

final class ZipWriterTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-writer-\(UUID().uuidString).zip")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeArchive(options: ZipWriter.Options = ZipWriter.Options(),
                             _ build: (ZipWriter) throws -> Void) throws -> URL {
        let writer = try ZipWriter(url: tempURL, options: options)
        try build(writer)
        try writer.finalize()
        return tempURL
    }

    // MARK: - Roundtrips through our reader

    func testRoundTripUTF8Names() throws {
        let url = try makeArchive { w in
            try w.addDirectory("サブフォルダ")
            try w.addFile("日本語ファイル.txt", data: Data("こんにちは Windows\n".utf8))
            try w.addFile("サブフォルダ/データ.csv", data: Data("月,売上\n".utf8))
            try w.addFile("readme.txt", data: Data("ascii\n".utf8))
        }
        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.count, 4)
        let jp = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "日本語ファイル.txt" })
        XCTAssertTrue(jp.flags.contains(.utf8Name))
        XCTAssertEqual(try reader.extractData(jp), Data("こんにちは Windows\n".utf8))
        let ascii = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "readme.txt" })
        XCTAssertFalse(ascii.flags.contains(.utf8Name), "pure-ASCII names must not set bit 11")
        let dir = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "サブフォルダ/" })
        XCTAssertTrue(dir.isDirectory)
    }

    func testNamesAreNFCNormalized() throws {
        let nfdName = "テ\u{3099}ータ.txt" // NFD input, as macOS file APIs produce
        let url = try makeArchive { try $0.addFile(nfdName, data: Data("x".utf8)) }
        let reader = try ZipReader(url: url)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(reader.name(of: entry), "データ.txt")
        XCTAssertEqual(reader.name(of: entry).unicodeScalars.first?.value, 0x30C7)
    }

    func testCP932NameEncoding() throws {
        var opts = ZipWriter.Options()
        opts.nameEncoding = .cp932
        let url = try makeArchive(options: opts) { w in
            try w.addFile("日本語ファイル.txt", data: Data("abc".utf8))
        }
        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.detectedEncoding, .cp932)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertFalse(entry.flags.contains(.utf8Name))
        XCTAssertEqual(reader.name(of: entry), "日本語ファイル.txt")
    }

    func testCP932UnmappableNameThrows() throws {
        var opts = ZipWriter.Options()
        opts.nameEncoding = .cp932
        let writer = try ZipWriter(url: tempURL, options: opts)
        XCTAssertThrowsError(try writer.addFile("🙂.txt", data: Data("x".utf8))) { error in
            XCTAssertEqual(error as? ZipWriterError, .nameNotEncodable("🙂.txt"))
        }
    }

    func testDuplicateNameThrows() throws {
        let writer = try ZipWriter(url: tempURL)
        try writer.addFile("a.txt", data: Data("1".utf8))
        XCTAssertThrowsError(try writer.addFile("a.txt", data: Data("2".utf8))) { error in
            XCTAssertEqual(error as? ZipWriterError, .duplicateName("a.txt"))
        }
    }

    func testOverlongNameThrowsInsteadOfTrapping() throws {
        // The name length is a 16-bit header field: converting a longer one
        // traps. No filesystem hands us such a path today — this guards the
        // conversion, not the filesystem.
        let writer = try ZipWriter(url: tempURL)
        let name = String(repeating: "a", count: 70_000)
        XCTAssertThrowsError(try writer.addFile(name, data: Data("x".utf8))) { error in
            XCTAssertEqual(error as? ZipWriterError, .nameTooLong(name))
        }
        // A name that exactly fills the field is still accepted.
        XCTAssertNoThrow(try writer.addFile(String(repeating: "b", count: 0xFFFF),
                                            data: Data("x".utf8)))
    }

    func testStoreExtensionSkipsDeflate() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        let url = try makeArchive { w in
            try w.addFile("photo.jpg", data: payload)
            try w.addFile("text.txt", data: Data(repeating: UInt8(ascii: "a"), count: 1000))
        }
        let reader = try ZipReader(url: url)
        let jpg = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "photo.jpg" })
        XCTAssertEqual(jpg.method, .store)
        XCTAssertEqual(jpg.compressedSize, 1000)
        let txt = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "text.txt" })
        XCTAssertEqual(txt.method, .deflate)
        XCTAssertLessThan(txt.compressedSize, 100)
        XCTAssertEqual(try reader.extractData(jpg), payload)
    }

    func testEmptyFileAndLargeRandomData() throws {
        var random = SystemRandomNumberGenerator()
        let big = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255, using: &random) })
        let url = try makeArchive { w in
            try w.addFile("empty.txt", data: Data())
            try w.addFile("big.bin", data: big)
        }
        let reader = try ZipReader(url: url)
        let empty = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "empty.txt" })
        XCTAssertEqual(try reader.extractData(empty), Data())
        let bigEntry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "big.bin" })
        XCTAssertEqual(try reader.extractData(bigEntry), big)
    }

    func testFileURLSourceStreams() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-src-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: src) }
        let payload = Data(repeating: UInt8(ascii: "z"), count: 3 << 20)
        try payload.write(to: src)
        let url = try makeArchive { try $0.addFile("big.txt", fileURL: src) }
        let reader = try ZipReader(url: url)
        XCTAssertEqual(try reader.extractData(try XCTUnwrap(reader.entries.first)), payload)
    }

    // MARK: - Encryption roundtrips

    func testZipCryptoRoundTrip() throws {
        var opts = ZipWriter.Options()
        opts.encryption = .zipCrypto(password: "p@ss日本語")
        let url = try makeArchive(options: opts) { w in
            try w.addFile("secret.txt", data: Data("confidential\n".utf8))
        }
        let reader = try ZipReader(url: url)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.encryption, .zipCrypto)
        XCTAssertEqual(try reader.extractData(entry, password: "p@ss日本語"),
                       Data("confidential\n".utf8))
        XCTAssertThrowsError(try reader.extractData(entry, password: "nope"))
    }

    func testAES256RoundTrip() throws {
        var opts = ZipWriter.Options()
        opts.encryption = .aes256(password: "p@ss日本語")
        let payload = Data((0..<100_000).map { UInt8($0 % 253) })
        let url = try makeArchive(options: opts) { w in
            try w.addFile("secret.bin", data: payload)
            try w.addFile("empty.txt", data: Data())
        }
        let reader = try ZipReader(url: url)
        let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "secret.bin" })
        guard case .aes(let strength, let vendor, _) = entry.encryption else {
            return XCTFail("expected AES, got \(entry.encryption)")
        }
        XCTAssertEqual(strength, .aes256)
        XCTAssertEqual(vendor, 2)
        XCTAssertEqual(entry.crc32, 0, "AE-2 zeroes the CRC field")
        XCTAssertEqual(try reader.extractData(entry, password: "p@ss日本語"), payload)
        XCTAssertThrowsError(try reader.extractData(entry, password: "nope")) { error in
            XCTAssertEqual(error as? ZipReaderError, .wrongPassword)
        }
        let empty = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "empty.txt" })
        XCTAssertEqual(try reader.extractData(empty, password: "p@ss日本語"), Data())
    }

    func testAESTamperedDataFailsAuthentication() throws {
        var opts = ZipWriter.Options()
        opts.encryption = .aes256(password: "pw")
        _ = try makeArchive(options: opts) { w in
            try w.addFile("a.bin", data: Data(repeating: 7, count: 5000))
        }
        var bytes = try Data(contentsOf: tempURL)
        // Flip one ciphertext byte mid-file (past headers, before the CD).
        let idx = bytes.count / 2
        bytes[idx] ^= 0xFF
        try bytes.write(to: tempURL)
        let reader = try ZipReader(url: tempURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertThrowsError(try reader.extractData(entry, password: "pw")) { error in
            guard case .authenticationFailed = error as? ZipReaderError else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    // MARK: - ZIP64

    func testZip64RoundTripWithForcedThreshold() throws {
        let writer = try ZipWriter(url: tempURL)
        writer.zip64Threshold = 100 // force the ZIP64 path with small data
        let payload = Data((0..<5000).map { UInt8($0 % 256) })
        try writer.addFile("big.bin", data: payload)
        try writer.finalize()
        let reader = try ZipReader(url: tempURL)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.uncompressedSize, 5000)
        XCTAssertEqual(try reader.extractData(entry), payload)
    }

    // MARK: - External tool verification

    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        try TestSupport.run(tool, args)
    }

    func testInfoZipUnzipAcceptsOurArchive() throws {
        let url = try makeArchive { w in
            try w.addDirectory("サブフォルダ")
            try w.addFile("日本語ファイル.txt", data: Data("こんにちは\n".utf8))
            try w.addFile("サブフォルダ/データ.csv", data: Data("a,b\n".utf8))
        }
        let result = try run("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(result.status, 0, "unzip -t rejected our archive: \(result.output)")
        XCTAssertTrue(result.output.contains("No errors detected"), result.output)
    }

    func testInfoZipUnzipAcceptsOurZipCrypto() throws {
        var opts = ZipWriter.Options()
        opts.encryption = .zipCrypto(password: "s3cret-pass")
        let url = try makeArchive(options: opts) { w in
            try w.addFile("secret.txt", data: Data("confidential\n".utf8))
        }
        let result = try run("/usr/bin/unzip", ["-t", "-P", "s3cret-pass", url.path])
        XCTAssertEqual(result.status, 0, "unzip -t -P rejected our ZipCrypto: \(result.output)")
    }

    func testDittoExtractsOurArchive() throws {
        let url = try makeArchive { w in
            try w.addFile("日本語ファイル.txt", data: Data("こんにちは\n".utf8))
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-ditto-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let result = try run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path])
        XCTAssertEqual(result.status, 0, result.output)
        let extracted = try Data(contentsOf: dest.appendingPathComponent("日本語ファイル.txt"))
        XCTAssertEqual(extracted, Data("こんにちは\n".utf8))
    }

    func testSevenZipExtractsOurAES() throws {
        let sevenZip = "/opt/homebrew/bin/7zz"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sevenZip), "7zz not installed")
        var opts = ZipWriter.Options()
        opts.encryption = .aes256(password: "s3cret-pass")
        let url = try makeArchive(options: opts) { w in
            try w.addFile("secret.txt", data: Data("confidential\n".utf8))
        }
        let result = try run(sevenZip, ["t", "-ps3cret-pass", url.path])
        XCTAssertEqual(result.status, 0, "7zz t rejected our AES archive: \(result.output)")
    }
}
