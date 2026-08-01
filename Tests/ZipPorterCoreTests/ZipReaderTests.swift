import XCTest
@testable import ZipPorterCore

/// Reader tests against fixtures produced by INDEPENDENT tools
/// (Info-ZIP zip, Apple ditto, a spec-derived Python generator, 7-Zip).
/// Regenerate with scripts/gen-fixtures.sh.
final class ZipReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "testdata"))
    }

    /// Entry lookup must be NFC/NFD-insensitive (ditto stores NFD).
    private func entry(_ reader: ZipReader, _ name: String) throws -> ZipEntry {
        let want = name.precomposedStringWithCanonicalMapping
        return try XCTUnwrap(reader.entries.first {
            reader.name(of: $0).precomposedStringWithCanonicalMapping == want
        }, "entry \(name) not found in \(reader.entries.map { reader.name(of: $0) })")
    }

    // MARK: - Plain archives

    func testInfoZipFixture() throws {
        let reader = try ZipReader(url: try fixture("infozip"))
        let jp = try entry(reader, "日本語ファイル.txt")
        XCTAssertEqual(try reader.extractData(jp), Data("こんにちは Windows\n".utf8))
        let csv = try entry(reader, "サブフォルダ/データ.csv")
        XCTAssertEqual(try reader.extractData(csv), Data("月,売上\n1月,100\n".utf8))
        XCTAssertEqual(try reader.extractData(try entry(reader, "readme.txt")),
                       Data("plain ascii content\n".utf8))
    }

    func testDittoFixtureDecodesNFDNames() throws {
        let reader = try ZipReader(url: try fixture("ditto"))
        let jp = try entry(reader, "日本語ファイル.txt")
        XCTAssertEqual(try reader.extractData(jp), Data("こんにちは Windows\n".utf8))
    }

    func testCP932FixtureAutoDetects() throws {
        let reader = try ZipReader(url: try fixture("cp932"))
        XCTAssertEqual(reader.detectedEncoding, .cp932)
        let jp = try entry(reader, "日本語.txt")
        XCTAssertFalse(jp.flags.contains(.utf8Name))
        XCTAssertEqual(try reader.extractData(jp),
                       "こんにちは\r\n".data(using: FileNameTransform.cp932))
        _ = try entry(reader, "フォルダ/データ.csv")
    }

    func testForcedEncodingOverridesDetection() throws {
        let reader = try ZipReader(url: try fixture("cp932"))
        // Forcing UTF-8 on CP932 names must not crash — it yields mojibake
        // or a fallback decode, but stays extractable.
        let names = reader.entries.map { reader.name(of: $0, forcedEncoding: .utf8) }
        XCTAssertEqual(names.count, 2)
    }

    // MARK: - Encrypted archives (decrypt side)

    func testZipCryptoFixtureDecrypts() throws {
        let reader = try ZipReader(url: try fixture("infozip-crypto"))
        let jp = try entry(reader, "日本語ファイル.txt")
        XCTAssertEqual(jp.encryption, .zipCrypto)
        XCTAssertEqual(try reader.extractData(jp, password: "s3cret-pass"),
                       Data("こんにちは Windows\n".utf8))
    }

    func testZipCryptoWrongPassword() throws {
        let reader = try ZipReader(url: try fixture("infozip-crypto"))
        let jp = try entry(reader, "日本語ファイル.txt")
        XCTAssertThrowsError(try reader.extractData(jp, password: "wrong-password")) { error in
            // 1/256 of wrong passwords pass the check byte and die on CRC.
            guard case let e as ZipReaderError = error,
                  e == .wrongPassword || e == .crcMismatch(entryName: "日本語ファイル.txt")
            else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertThrowsError(try reader.extractData(jp)) { error in
            XCTAssertEqual(error as? ZipReaderError, .passwordRequired)
        }
    }

    func testSevenZipAES256Decrypts() throws {
        let reader = try ZipReader(url: try fixture("sevenzip-aes256"))
        let jp = try entry(reader, "日本語ファイル.txt")
        guard case .aes(let strength, _, _) = jp.encryption else {
            return XCTFail("expected AES encryption, got \(jp.encryption)")
        }
        XCTAssertEqual(strength, .aes256)
        XCTAssertEqual(try reader.extractData(jp, password: "s3cret-pass"),
                       Data("こんにちは Windows\n".utf8))
        XCTAssertEqual(try reader.extractData(try entry(reader, "サブフォルダ/データ.csv"),
                                              password: "s3cret-pass"),
                       Data("月,売上\n1月,100\n".utf8))
    }

    func testSevenZipAES128Decrypts() throws {
        let reader = try ZipReader(url: try fixture("sevenzip-aes128"))
        let jp = try entry(reader, "日本語ファイル.txt")
        guard case .aes(let strength, _, _) = jp.encryption else {
            return XCTFail("expected AES encryption, got \(jp.encryption)")
        }
        XCTAssertEqual(strength, .aes128)
        XCTAssertEqual(try reader.extractData(jp, password: "s3cret-pass"),
                       Data("こんにちは Windows\n".utf8))
    }

    func testAESWrongPasswordFailsVerifier() throws {
        let reader = try ZipReader(url: try fixture("sevenzip-aes256"))
        let jp = try entry(reader, "日本語ファイル.txt")
        XCTAssertThrowsError(try reader.extractData(jp, password: "wrong-password")) { error in
            XCTAssertEqual(error as? ZipReaderError, .wrongPassword)
        }
    }

    // MARK: - Corruption

    func testRandomDataIsNotAZip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-notazip-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        XCTAssertThrowsError(try ZipReader(url: url))
    }

    func testTruncatedArchiveThrows() throws {
        let whole = try Data(contentsOf: try fixture("infozip"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-truncated-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try whole.prefix(whole.count / 3).write(to: url)
        XCTAssertThrowsError(try ZipReader(url: url))
    }
}
