import XCTest
@testable import ZipPorterCore

/// The structure half of the failure report (ADR-0007): what the central
/// directory says about the writer and the failing entry — and nothing
/// that is a name.
final class ArchiveDiagnosticsTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "testdata"))
    }

    struct RawEntry {
        var name: String
        var method: UInt16 = 0
        var payload = Data()
        var uncompressedSize: UInt32?
        var crc: UInt32 = 0
        var flags: UInt16 = 0x0800
        var versionMadeBy: UInt16 = 20
        var versionNeeded: UInt16 = 20
        var extra = Data()
    }

    /// An archive written byte by byte, so method, made-by and extra fields
    /// can be anything — including what no writer of ours produces.
    private func rawZip(_ entries: [RawEntry]) throws -> URL {
        var body = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let size = entry.uncompressedSize ?? UInt32(entry.payload.count)
            let offset = UInt32(body.count)
            body.appendU32(Zip.localHeaderSignature)
            for v: UInt16 in [entry.versionNeeded, entry.flags, entry.method, 0, 0] { body.appendU16(v) }
            body.appendU32(entry.crc)
            body.appendU32(UInt32(entry.payload.count))
            body.appendU32(size)
            body.appendU16(UInt16(name.count))
            body.appendU16(0)
            body.append(name)
            body.append(entry.payload)

            central.appendU32(Zip.centralHeaderSignature)
            for v: UInt16 in [entry.versionMadeBy, entry.versionNeeded, entry.flags, entry.method, 0, 0] {
                central.appendU16(v)
            }
            central.appendU32(entry.crc)
            central.appendU32(UInt32(entry.payload.count))
            central.appendU32(size)
            for v: UInt16 in [UInt16(name.count), UInt16(entry.extra.count), 0, 0, 0] { central.appendU16(v) }
            central.appendU32(0)
            central.appendU32(offset)
            central.append(name)
            central.append(entry.extra)
        }
        var eocd = Data()
        eocd.appendU32(Zip.eocdSignature)
        for v: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { eocd.appendU16(v) }
        eocd.appendU32(UInt32(central.count))
        eocd.appendU32(UInt32(body.count))
        eocd.appendU16(0)
        let url = workDir.appendingPathComponent("raw-\(UUID().uuidString).zip")
        try (body + central + eocd).write(to: url)
        return url
    }

    private func extraField(_ id: UInt16, _ content: Data) -> Data {
        var d = Data()
        d.appendU16(id)
        d.appendU16(UInt16(content.count))
        d.append(content)
        return d
    }

    // MARK: - What the reader keeps for the report

    func testReaderKeepsVersionNeededAndExtraFieldIDs() throws {
        let extra = extraField(0x5455, Data([1, 0, 0, 0, 0])) + extraField(0x7875, Data([1, 4, 0, 0, 0, 0]))
        let url = try rawZip([RawEntry(name: "a.txt", versionMadeBy: (3 << 8) | 30,
                                       versionNeeded: 46, extra: extra)])
        let entry = try XCTUnwrap(try ZipReader(url: url).entries.first)
        XCTAssertEqual(entry.versionNeeded, 46)
        XCTAssertEqual(entry.extraFieldIDs, [0x5455, 0x7875])
    }

    /// A length that overshoots stops the walk short of the end: whatever
    /// came after the bad length was field data, so no ID is kept at all —
    /// a Unicode Path field (0x7075) would otherwise lend its name bytes.
    func testExtraFieldsWhoseLengthsDoNotAddUpKeepNoIDs() throws {
        var extra = extraField(0x5455, Data([1, 0, 0, 0, 0]))
        extra.appendU16(0x7075)
        extra.appendU16(40)                 // claims 40 bytes; 6 follow
        extra.append(Data("secret".utf8))
        let url = try rawZip([RawEntry(name: "a.txt", extra: extra)])
        let entry = try XCTUnwrap(try ZipReader(url: url).entries.first)
        XCTAssertNil(entry.extraFieldIDs)
        let lines = ArchiveDiagnostics.lines(entries: [entry], archiveSize: 0,
                                             hasZip64Directory: false, failingEntry: 0)
        XCTAssertTrue(lines.contains("extra fields: malformed x1"), "\(lines)")
        XCTAssertTrue(lines.contains("  extra fields: malformed"), "\(lines)")
    }

    func testCentralDirectoryIsReadableWhenOpeningRefusesTheArchive() throws {
        // Overlapping ranges are refused at open — exactly the archive whose
        // structure the report has to describe.
        let url = try fixture("hostile-overlap")
        XCTAssertThrowsError(try ZipReader(url: url))
        let directory = try ZipReader.centralDirectory(of: url)
        XCTAssertGreaterThan(directory.entries.count, 1)
        XCTAssertGreaterThan(directory.archiveSize, 0)
    }

    // MARK: - The summary

    func testSevenZipDeflate64FixtureReadsAsWhatItIs() throws {
        let directory = try ZipReader.centralDirectory(of: try fixture("sevenzip-deflate64"))
        let lines = ArchiveDiagnostics.lines(entries: directory.entries,
                                             archiveSize: directory.archiveSize,
                                             hasZip64Directory: directory.hasZip64Directory,
                                             failingEntry: nil)
        XCTAssertTrue(lines[0].hasPrefix("size: \(directory.archiveSize) bytes, \(directory.entries.count) entries"),
                      lines[0])
        XCTAssertTrue(lines[0].hasSuffix("zip64 directory: no"), lines[0])
        // gen-fixtures.sh: four small files 7-Zip stores, two it compresses.
        XCTAssertTrue(lines.contains("methods: store (0) x4, deflate64 (9) x2"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("version needed:") && $0.contains("2.1 x2") },
                      "Deflate64 entries need 2.1: \(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("failing entry") })
    }

    func testFailingEntryIsDescribedByItsShape() throws {
        let url = try rawZip([
            RawEntry(name: "dir/", versionMadeBy: 20),
            RawEntry(name: "dir/b.bin", method: 12, payload: Data([1, 2, 3]), uncompressedSize: 9,
                     flags: 0x0808, versionMadeBy: (10 << 8) | 63, versionNeeded: 46,
                     extra: extraField(0x000a, Data(count: 32))),
        ])
        let directory = try ZipReader.centralDirectory(of: url)
        let lines = ArchiveDiagnostics.lines(entries: directory.entries,
                                             archiveSize: directory.archiveSize,
                                             hasZip64Directory: false, failingEntry: 1)
        XCTAssertEqual(Array(lines.suffix(5)), [
            "failing entry: #2 of 2",
            "  method 12, none, flags 0x0808",
            "  made by ntfs 6.3, needs 4.6",
            "  3 -> 9 bytes",
            "  extra fields: 0x000a",
        ])
        XCTAssertTrue(lines.contains("methods: method 12 x1, store (0) x1"), "\(lines)")
        XCTAssertTrue(lines.contains("made by: fat 2.0 x1, ntfs 6.3 x1"), "\(lines)")
        XCTAssertTrue(lines.contains("flags: data descriptor x1, utf-8 names x2"), "\(lines)")
        XCTAssertTrue(lines[0].contains("2 entries (1 directories)"), lines[0])
    }

    func testDirectoryFailingEntryIsMarked() throws {
        let url = try rawZip([RawEntry(name: "dir/")])
        let directory = try ZipReader.centralDirectory(of: url)
        let lines = ArchiveDiagnostics.lines(entries: directory.entries, archiveSize: 0,
                                             hasZip64Directory: false, failingEntry: 0)
        XCTAssertTrue(lines.contains("failing entry: #1 of 1 (directory)"), "\(lines)")
    }

    func testOutOfRangeFailingEntryIsLeftOut() {
        let lines = ArchiveDiagnostics.lines(entries: [], archiveSize: 22,
                                             hasZip64Directory: false, failingEntry: 3)
        XCTAssertFalse(lines.contains { $0.hasPrefix("failing entry") })
        XCTAssertTrue(lines.contains("methods: none"), "\(lines)")
    }

    func testTallyPutsTheCommonestFirstAndBreaksTiesByLabel() {
        XCTAssertEqual(ArchiveDiagnostics.tally(["b", "a", "c", "c"]), "c x2, a x1, b x1")
        XCTAssertEqual(ArchiveDiagnostics.tally([]), "none")
    }

    /// Names, CRCs and times never appear — the report's one promise.
    func testNoNameCrcOrTimeReachesTheSummary() throws {
        let marker = "MARKER"
        let url = try rawZip([
            RawEntry(name: "\(marker)/", versionMadeBy: 20),
            RawEntry(name: "\(marker)/\(marker).bin", method: 12, payload: Data([1, 2, 3]),
                     crc: 0xDEAD_BEEF,
                     extra: extraField(0x7075, Data([1, 0, 0, 0, 0]) + Data("\(marker).bin".utf8))),
        ])
        let directory = try ZipReader.centralDirectory(of: url)
        let text = ArchiveDiagnostics.lines(entries: directory.entries,
                                            archiveSize: directory.archiveSize,
                                            hasZip64Directory: false, failingEntry: 1)
            .joined(separator: "\n")
        XCTAssertFalse(text.contains(marker), text)
        XCTAssertFalse(text.lowercased().contains("deadbeef"), text)
        XCTAssertFalse(text.contains("\(0xDEAD_BEEF)"), text)
    }

    // MARK: - Unpacker names the failing entry by index

    func testUnpackerReportsTheIndexOfTheEntryThatFailed() throws {
        let url = try rawZip([
            RawEntry(name: "dir/"),
            RawEntry(name: "dir/ok.txt", payload: Data("ok".utf8), crc: 0x79DC_DD47),
            RawEntry(name: "dir/bad.bin", method: 12, payload: Data([1, 2, 3])),
        ])
        var reported: [Int] = []
        XCTAssertThrowsError(try Unpacker.unpack(
            zipURL: url, options: optionsInto(workDir.appendingPathComponent("out")),
            failingEntry: { reported.append($0) })) { error in
            XCTAssertEqual(error as? ZipReaderError, .unsupportedMethod(12))
        }
        XCTAssertEqual(reported, [2])
    }

    func testIndexCountsEntriesExtractionSkips() throws {
        // A skipped symlink-or-unsafe entry still occupies its place in the
        // central directory; the index is the directory's, not the work list's.
        let url = try rawZip([
            RawEntry(name: "../escape.txt", payload: Data("x".utf8)),
            RawEntry(name: "bad.bin", method: 12, payload: Data([1])),
        ])
        var reported: [Int] = []
        XCTAssertThrowsError(try Unpacker.unpack(
            zipURL: url, options: optionsInto(workDir.appendingPathComponent("out")),
            failingEntry: { reported.append($0) }))
        XCTAssertEqual(reported, [1])
    }

    func testFailuresOutsideAnyEntryReportNoIndex() throws {
        let url = try rawZip([RawEntry(name: "../escape.txt", payload: Data("x".utf8))])
        var reported: [Int] = []
        XCTAssertThrowsError(try Unpacker.unpack(
            zipURL: url, options: optionsInto(workDir.appendingPathComponent("out")),
            failingEntry: { reported.append($0) })) { error in
            XCTAssertEqual(error as? Unpacker.Failure, .emptyArchive)
        }
        XCTAssertEqual(reported, [])
    }

    func testDamagedDeflateDataIsAnEntryCorruption() throws {
        // 0xFF opens a block of the reserved type 3.
        let url = try rawZip([RawEntry(name: "a.txt", method: 8, payload: Data([0xFF, 0xFF, 0xFF]),
                                       uncompressedSize: 10)])
        let reader = try ZipReader(url: url)
        XCTAssertThrowsError(try reader.extractData(reader.entries[0])) { error in
            XCTAssertEqual(error as? ZipReaderError,
                           .entryCorrupt(entryName: "a.txt", detail: "Deflate stream is invalid"))
        }
    }

    private func optionsInto(_ destination: URL) -> Unpacker.Options {
        var options = Unpacker.Options()
        options.destination = destination
        return options
    }
}
