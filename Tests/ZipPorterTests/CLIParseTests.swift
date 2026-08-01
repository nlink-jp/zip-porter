import XCTest
@testable import ZipPorter

final class CLIParseTests: XCTestCase {
    func testPackDefaults() throws {
        let parsed = try CLIParse.pack(["docs"]).get()
        XCTAssertEqual(parsed.inputs, ["docs"])
        XCTAssertNil(parsed.output)
        XCTAssertFalse(parsed.askPassword)
        XCTAssertFalse(parsed.cp932)
        XCTAssertFalse(parsed.zipCrypto)
        XCTAssertFalse(parsed.noClean)
    }

    func testPackAllFlags() throws {
        let parsed = try CLIParse.pack(
            ["docs", "extra.txt", "-o", "out.zip", "--password", "--cp932", "--zipcrypto", "--no-clean"]).get()
        XCTAssertEqual(parsed.inputs, ["docs", "extra.txt"])
        XCTAssertEqual(parsed.output, "out.zip")
        XCTAssertTrue(parsed.askPassword && parsed.cp932 && parsed.zipCrypto && parsed.noClean)
    }

    func testPackRequiresInput() {
        XCTAssertThrowsError(try CLIParse.pack([]).get())
    }

    func testPackMultipleInputsRequireOutput() {
        XCTAssertThrowsError(try CLIParse.pack(["a", "b"]).get())
    }

    func testPackZipCryptoRequiresPassword() {
        XCTAssertThrowsError(try CLIParse.pack(["docs", "--zipcrypto"]).get())
    }

    func testPackRejectsUnknownFlag() {
        XCTAssertThrowsError(try CLIParse.pack(["docs", "--fast"]).get())
    }

    func testUnpackDefaults() throws {
        let parsed = try CLIParse.unpack(["a.zip"]).get()
        XCTAssertEqual(parsed.input, "a.zip")
        XCTAssertNil(parsed.output)
        XCTAssertEqual(parsed.encoding, "auto")
    }

    func testUnpackFlags() throws {
        let parsed = try CLIParse.unpack(["a.zip", "-o", "dest", "--password", "--encoding", "cp932"]).get()
        XCTAssertEqual(parsed.output, "dest")
        XCTAssertTrue(parsed.askPassword)
        XCTAssertEqual(parsed.encoding, "cp932")
    }

    func testUnpackRejectsBadEncoding() {
        XCTAssertThrowsError(try CLIParse.unpack(["a.zip", "--encoding", "sjis"]).get())
    }

    func testUnpackRequiresExactlyOneInput() {
        XCTAssertThrowsError(try CLIParse.unpack([]).get())
        XCTAssertThrowsError(try CLIParse.unpack(["a.zip", "b.zip"]).get())
    }

    func testInspect() throws {
        XCTAssertEqual(try CLIParse.inspect(["a.zip"]).get().input, "a.zip")
        XCTAssertThrowsError(try CLIParse.inspect([]).get())
        XCTAssertThrowsError(try CLIParse.inspect(["a.zip", "--verbose"]).get())
    }
}
