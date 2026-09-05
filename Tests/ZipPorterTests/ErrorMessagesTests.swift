import XCTest
@testable import ZipPorter
@testable import ZipPorterCore

/// The failure paths ADR-0005 made more common must read as sentences, not
/// as Swift enum dumps or a POSIX line naming an internal file. Assertions
/// compare against L() so they hold under any process locale.
final class ErrorMessagesTests: XCTestCase {
    func testNameTakenDuringExtractionNamesTheItemAndSaysNothingWasExtracted() {
        let error = PathUtil.posixError(EEXIST, at: URL(fileURLWithPath: "/tmp/dest/report.txt"))
        XCTAssertEqual(ErrorMessages.takenName(from: error), "report.txt")
        let message = ErrorMessages.describe(error)
        XCTAssertTrue(message.hasPrefix(L("Another item appeared at a name this extraction was about to use, so nothing was extracted. Try again.")), message)
        XCTAssertTrue(message.hasSuffix("\nreport.txt"), message)
    }

    func testOtherPosixErrorsAreNotMistakenForATakenName() {
        let error = PathUtil.posixError(EACCES, at: URL(fileURLWithPath: "/tmp/dest/report.txt"))
        XCTAssertNil(ErrorMessages.takenName(from: error))
        XCTAssertEqual(ErrorMessages.describe(error), error.localizedDescription)
        XCTAssertNil(ErrorMessages.takenName(from: ZipReaderError.notAZipFile))
    }

    func testWriteFailuresReadAsASentenceWithTheCause() {
        let message = ErrorMessages.describe(
            ZipWriterError.ioError("cannot create a scratch file beside the archive: Permission denied"))
        XCTAssertTrue(message.hasPrefix(L("The archive could not be written.")), message)
        XCTAssertTrue(message.contains("Permission denied"), message)
        XCTAssertFalse(message.contains("ioError("), "no enum dump: \(message)")
    }

    func testMalformedArchivesRefusedAtOpenReadAsASentenceWithTheDetail() {
        let message = ErrorMessages.describe(ZipReaderError.corrupt("local header at 32"))
        XCTAssertTrue(message.hasPrefix(L("The archive is malformed and was refused.")), message)
        XCTAssertTrue(message.hasSuffix("\nlocal header at 32"), message)
        XCTAssertFalse(message.contains("corrupt("), "no enum dump: \(message)")
    }

    func testExistingMessagesAreUnchanged() {
        XCTAssertEqual(ErrorMessages.describe(ZipReaderError.notAZipFile), L("This file is not a ZIP archive."))
        XCTAssertEqual(ErrorMessages.describe(Unpacker.Failure.emptyArchive),
                       L("The archive contains nothing that can be extracted."))
        XCTAssertTrue(ErrorMessages.describe(ZipWriterError.nameNotEncodable("①"))
            .hasPrefix(L("This name cannot be stored as CP932:")))
    }
}
