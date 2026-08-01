import XCTest
@testable import ZipPorterCore

final class FileNameTransformTests: XCTestCase {
    func testNFCComposesDakuten() {
        // "ポ" as NFD (ホ U+30DB + combining handakuten U+309A) → NFC U+30DD.
        let nfd = "\u{30DB}\u{309A}"
        let nfc = FileNameTransform.nfc(nfd)
        XCTAssertEqual(nfc.unicodeScalars.map(\.value), [0x30DD])
    }

    func testNFCLeavesComposedInputUntouched() {
        XCTAssertEqual(FileNameTransform.nfc("データ.txt"), "データ.txt")
    }

    func testCP932RoundTripsJapaneseName() throws {
        let name = "日本語ファイル名.txt"
        let bytes = try XCTUnwrap(FileNameTransform.encodeCP932(name))
        XCTAssertEqual(FileNameTransform.decodeCP932(bytes), name)
    }

    func testCP932EncodesNFDInputAsComposed() throws {
        // macOS hands over NFD; CP932 has no combining marks, so encoding
        // must go through NFC first to succeed.
        let nfdName = "テ\u{3099}ータ.txt" // "デ" decomposed
        let bytes = try XCTUnwrap(FileNameTransform.encodeCP932(nfdName))
        XCTAssertEqual(FileNameTransform.decodeCP932(bytes), "データ.txt")
    }

    func testCP932AcceptsMicrosoftExtensions() {
        // NEC/IBM extension chars exist in CP932 but not in plain Shift_JIS.
        XCTAssertNotNil(FileNameTransform.encodeCP932("①㈱.txt"))
    }

    func testCP932RejectsUnmappableCharacters() {
        XCTAssertNil(FileNameTransform.encodeCP932("🙂.txt"))
    }

    func testDecodeCP932RejectsTruncatedDoubleByte() {
        // A lone lead byte (0x93 starts a double-byte sequence) must not decode.
        XCTAssertNil(FileNameTransform.decodeCP932(Data([0x93])))
    }

    func testDecodeCP932PlainASCII() {
        XCTAssertEqual(FileNameTransform.decodeCP932(Data("report.pdf".utf8)), "report.pdf")
    }
}
