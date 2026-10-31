import XCTest
@testable import ZipPorter
@testable import ZipPorterCore

/// The "Copy Details" text (ADR-0007). Its one promise is that it can be
/// forwarded unread: no file name, entry name, path or content, whatever
/// failed. Every name in these tests carries a marker the report must not
/// contain.
final class FailureReportTests: XCTestCase {
    private let marker = "MARKER"
    private let environment = FailureReport.Environment(appVersion: "9.9.9", osVersion: "Version 27.2")
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("failure-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - No names, whatever failed

    func testEveryNameCarryingErrorRendersWithoutTheName() {
        let path = "/Users/someone/\(marker)/\(marker).zip"
        let errors: [Error] = [
            ZipReaderError.crcMismatch(entryName: marker),
            ZipReaderError.authenticationFailed(entryName: marker),
            ZipReaderError.sizeExceedsDeclared(entryName: marker),
            ZipReaderError.entryCorrupt(entryName: marker, detail: "Deflate stream is invalid"),
            ZipReaderError.unsupportedFeature(marker),
            ZipWriterError.nameNotEncodable(marker),
            ZipWriterError.nameTooLong(marker),
            ZipWriterError.duplicateName(marker),
            ZipWriterError.ioError("cannot create \(marker).zip: Permission denied"),
            Unpacker.Failure.destinationNotADirectory(path),
            Packer.Failure.inputNotFound(path),
            PathUtil.posixError(EEXIST, at: URL(fileURLWithPath: path)),
            NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "“\(marker)” could not be saved.",
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28,
                                              userInfo: [NSFilePathErrorKey: path]),
            ]),
        ]
        for error in errors {
            let line = FailureReport.describe(error)
            XCTAssertFalse(line.contains(marker), "\(error) → \(line)")
            XCTAssertFalse(line.contains("someone"), "\(error) → \(line)")
        }
    }

    func testForeignErrorsReportTheirDomainAndCodeDownTheChain() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28),
        ])
        XCTAssertEqual(FailureReport.describe(error), "NSCocoaErrorDomain 640 <- NSPOSIXErrorDomain 28")
    }

    func testOwnErrorsKeepTheirNameFreePayload() {
        XCTAssertEqual(FailureReport.describe(ZipReaderError.unsupportedMethod(9)),
                       "ZipReaderError.unsupportedMethod(9)")
        XCTAssertEqual(FailureReport.describe(ZipReaderError.entryCorrupt(entryName: marker,
                                                                          detail: "Deflate64 stream ends early")),
                       "ZipReaderError.entryCorrupt: Deflate64 stream ends early")
        XCTAssertEqual(FailureReport.describe(Unpacker.Failure.insufficientSpace(required: 10, available: 3)),
                       "Unpacker.Failure.insufficientSpace(required: 10, available: 3)")
    }

    /// End to end: a real extraction failure in an archive whose own name
    /// and every entry name carry the marker.
    func testReportOfARealFailureCarriesNoName() throws {
        let zip = workDir.appendingPathComponent("\(marker) 売上.zip")
        let writer = try ZipWriter(url: zip)
        try writer.addDirectory("\(marker)/")
        try writer.addFile("\(marker)/\(marker)-1.txt", data: Data("first".utf8))
        try writer.addFile("\(marker)/\(marker)-2.txt", data: Data(repeating: 0x41, count: 4096))
        try writer.finalize()
        try corruptLastByteOfPayload(in: zip, entry: 2)

        var options = Unpacker.Options()
        options.destination = workDir.appendingPathComponent("out")
        var failingEntry: Int?
        var thrown: Error?
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: zip, options: options,
                                                 failingEntry: { failingEntry = $0 })) { thrown = $0 }
        let error = try XCTUnwrap(thrown)
        XCTAssertEqual(failingEntry, 2)

        let section = FailureReport.section(
            position: 0, error: FailureReport.describe(error),
            structure: FailureReport.structure(of: zip, failingEntry: failingEntry))
        let report = FailureReport.compose(environment: environment, operation: "extract",
                                           requested: 1, sections: [section])
        XCTAssertFalse(report.contains(marker), report)
        XCTAssertFalse(report.contains("売上"), report)
        XCTAssertFalse(report.contains(workDir.path), report)
        XCTAssertTrue(report.contains("failing entry: #3 of 3"), report)
    }

    /// Damage the compressed bytes of entry `index` so it fails its check.
    private func corruptLastByteOfPayload(in zip: URL, entry index: Int) throws {
        let reader = try ZipReader(url: zip)
        let entry = reader.entries[index]
        let position = Int(entry.dataOffset + entry.compressedSize - 1)
        var bytes = try Data(contentsOf: zip)
        bytes[position] ^= 0xFF
        try bytes.write(to: zip)
    }

    // MARK: - Format

    /// Pasted into mail by people on any locale: the whole report is
    /// ASCII, including the OS line (whose ready-made string is localized).
    func testReportIsPlainASCII() throws {
        let zip = workDir.appendingPathComponent("a.zip")
        let writer = try ZipWriter(url: zip)
        try writer.addFile("a.txt", data: Data("x".utf8))
        try writer.finalize()
        let report = FailureReport.compose(
            environment: .current, operation: "extract", requested: 1,
            sections: [FailureReport.section(
                position: 0, error: FailureReport.describe(ZipReaderError.unsupportedMethod(12)),
                structure: FailureReport.structure(of: zip, failingEntry: 0))])
        XCTAssertTrue(report.unicodeScalars.allSatisfy(\.isASCII), report)
        XCTAssertTrue(FailureReport.Environment.osVersion().first?.isNumber == true,
                      FailureReport.Environment.osVersion())
    }

    func testComposeNumbersArchivesWithinTheRequest() {
        let report = FailureReport.compose(
            environment: environment, operation: "extract", requested: 3,
            sections: [FailureReport.section(position: 1, error: "E", structure: ["size: 1 bytes"])])
        XCTAssertEqual(report, """
            ZipPorter failure report
            version: 9.9.9
            macOS: Version 27.2
            operation: extract, 3 requested, 1 failed

            archive 2 of 3
              error: E
              size: 1 bytes

            """)
    }

    func testUnparseableArchiveSaysSoInsteadOfInventingAStructure() throws {
        let url = workDir.appendingPathComponent("not-a-zip.zip")
        try Data("plain text".utf8).write(to: url)
        XCTAssertNil(FailureReport.structure(of: url, failingEntry: nil))
        XCTAssertEqual(FailureReport.section(position: 0, error: "E", structure: nil).lines,
                       ["error: E", "structure: unreadable"])
    }

    // MARK: - Batch

    func testBatchReportCoversOnlyFailuresThatCarryOne() throws {
        var batch = ExtractionBatch(requested: 3)
        XCTAssertNil(batch.failureReport(environment: environment), "no failure, no Copy Details")
        batch.record(ExtractionBatch.Failure(archive: "\(marker).zip", reason: "damaged"))
        XCTAssertNil(batch.failureReport(environment: environment))
        batch.record(ExtractionBatch.Failure(
            archive: "\(marker)-2.zip", reason: "damaged",
            report: FailureReport.section(position: 2, error: "E", structure: nil)))
        let report = try XCTUnwrap(batch.failureReport(environment: environment))
        XCTAssertTrue(report.contains("archive 3 of 3"), report)
        XCTAssertFalse(report.contains(marker), report)
    }

    // MARK: - CLI

    func testCLIMessageIsTheSameSentenceAsBefore() {
        XCTAssertEqual(CLIRun.unpackFailureMessage(ZipReaderError.unsupportedMethod(12), input: "a.zip"),
                       "unsupported compression method 12")
        XCTAssertEqual(CLIRun.unpackFailureMessage(ZipReaderError.notAZipFile, input: "a.zip"),
                       "'a.zip' is not a ZIP archive")
    }
}
