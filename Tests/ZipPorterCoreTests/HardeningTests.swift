import XCTest
@testable import ZipPorterCore

/// ADR-012 hardening, exercised against hostile archives built straight
/// from the format spec (scripts/gen-hostile-fixtures.py) — our own writer
/// cannot produce these structures.
final class HardeningTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "testdata"))
    }

    private func unpackOptions() -> Unpacker.Options {
        var options = Unpacker.Options()
        options.destination = workDir
        return options
    }

    // MARK: - Decompression bombs (ADR-012 §1)

    func testSizeLyingBombStopsAtDeclaredSize() throws {
        // Declares 1 KiB, actually inflates to 64 MiB.
        let reader = try ZipReader(url: try fixture("hostile-size-lie"))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.uncompressedSize, 1024)

        var produced = 0
        XCTAssertThrowsError(try reader.extract(entry) { produced += $0.count }) { error in
            guard case .sizeExceedsDeclared = error as? ZipReaderError else {
                return XCTFail("expected sizeExceedsDeclared, got \(error)")
            }
        }
        // The whole point: we stopped near the declared size, not at 64 MiB.
        XCTAssertLessThanOrEqual(produced, 1024 + (256 << 10),
                                 "output must be bounded by the declared size, not the real one")
    }

    func testSizeLyingBombLeavesNoFileBehind() throws {
        XCTAssertThrowsError(try Unpacker.unpack(
            zipURL: try fixture("hostile-size-lie"), options: unpackOptions()))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertEqual(leftovers, [], "a rejected bomb must leave nothing on disk")
    }

    // MARK: - Overlapping entries (ADR-012 §3)

    func testOverlapBombIsRejectedAtOpen() throws {
        // 200 central-directory entries pointing at one 8 MiB payload:
        // rejection must happen while parsing, before any extraction.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-overlap"))) { error in
            XCTAssertEqual(error as? ZipReaderError, .overlappingEntries)
        }
    }

    func testLegitimateArchivesPassTheOverlapCheck() throws {
        // Guard against the check being too strict: every honest fixture,
        // including ones with empty files and directories, must still open.
        for name in ["infozip", "ditto", "cp932", "infozip-crypto",
                     "sevenzip-aes128", "sevenzip-aes256"] {
            XCTAssertNoThrow(try ZipReader(url: try fixture(name)), "\(name) must remain readable")
        }
        // And one we wrote ourselves, with a directory + empty file + data.
        let ours = workDir.appendingPathComponent("ours.zip")
        let writer = try ZipWriter(url: ours)
        try writer.addDirectory("docs")
        try writer.addFile("docs/empty.txt", data: Data())
        try writer.addFile("docs/a.txt", data: Data("A".utf8))
        try writer.finalize()
        XCTAssertNoThrow(try ZipReader(url: ours))
    }

    // MARK: - Malformed ZIP64 headers
    //
    // Both fixtures are shaped to make a reader compute an out-of-range file
    // offset *while checking whether it is in range*. What these tests assert
    // is really that the process survives: an unchecked UInt64 subtraction or
    // addition here is a trap, and a trap in the parser takes the GUI down
    // with a double-clicked .zip.

    func testZip64LocatorBeforeFileStartIsRejected() throws {
        // 22-byte file: an EOCD at offset 0 claiming ZIP64, so the locator
        // would live at offset -20.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-zip64-locator-underflow"))) { error in
            guard case .corrupt = error as? ZipReaderError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    func testZip64CentralDirectoryBoundsThatOverflowAreRejected() throws {
        // cdSize + cdOffset wraps UInt64; the directory is nowhere near the
        // 98-byte file either way.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-zip64-size-overflow"))) { error in
            guard case .corrupt = error as? ZipReaderError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    func testTruncatedArchiveIsRejected() throws {
        // Header promises 1 MiB of data in a 124-byte file.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-truncated"))) { error in
            guard case .corrupt = error as? ZipReaderError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    // MARK: - Space budget (ADR-012 §2)

    func testInsufficientSpaceIsRefusedBeforeWriting() throws {
        // A declared total far beyond any real volume must be refused, and
        // refused before anything lands on disk.
        let huge = workDir.appendingPathComponent("huge.zip")
        try makeArchiveDeclaring(bytes: 1 << 60, at: huge)
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: huge, options: unpackOptions())) { error in
            guard case .insufficientSpace(let required, _) = error as? Unpacker.Failure else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
            XCTAssertEqual(required, 1 << 60)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0 != "huge.zip" }
        XCTAssertEqual(leftovers, [])
    }

    func testDeclaredTotalThatWrapsIsSaturatedNotBelieved() throws {
        // Two ZIP64 entries declaring 2^63 apiece: summed with wrapping
        // arithmetic the total is exactly zero, and the budget check — the
        // only thing standing between a bomb and the disk once every
        // individual entry is honest about its own size — waves it through.
        let archive = try fixture("hostile-declared-size-wrap")
        let reader = try ZipReader(url: archive)
        XCTAssertEqual(reader.entries.count, 2)
        XCTAssertEqual(reader.declaredTotalSize, .max,
                       "a total that cannot fit UInt64 must saturate, not wrap to a small number")

        XCTAssertThrowsError(try Unpacker.unpack(zipURL: archive, options: unpackOptions())) { error in
            guard case .insufficientSpace = error as? Unpacker.Failure else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertEqual(leftovers, [], "a refused archive must leave nothing on disk")
    }

    func testNormalArchivePassesTheBudgetCheck() throws {
        let ours = workDir.appendingPathComponent("small.zip")
        let writer = try ZipWriter(url: ours)
        try writer.addFile("docs/a.txt", data: Data("A".utf8))
        try writer.finalize()
        XCTAssertNoThrow(try Unpacker.unpack(zipURL: ours, options: unpackOptions()))
    }

    /// Hand-build a one-entry archive whose central directory claims a
    /// preposterous uncompressed size (ZIP64 fields, no real payload).
    private func makeArchiveDeclaring(bytes: UInt64, at url: URL) throws {
        let name = Data("huge.bin".utf8)
        var zip64Extra = Data()
        zip64Extra.appendU16(Zip.ExtraID.zip64)
        zip64Extra.appendU16(16)
        zip64Extra.appendU64(bytes) // uncompressed
        zip64Extra.appendU64(0) // compressed

        var local = Data()
        local.appendU32(Zip.localHeaderSignature)
        local.appendU16(45)
        local.appendU16(0)
        local.appendU16(0) // store
        local.appendU16(0)
        local.appendU16(0)
        local.appendU32(0)
        local.appendU32(0xFFFF_FFFF)
        local.appendU32(0xFFFF_FFFF)
        local.appendU16(UInt16(name.count))
        local.appendU16(UInt16(zip64Extra.count))
        local.append(name)
        local.append(zip64Extra)

        var central = Data()
        central.appendU32(Zip.centralHeaderSignature)
        central.appendU16(45)
        central.appendU16(45)
        central.appendU16(0)
        central.appendU16(0)
        central.appendU16(0)
        central.appendU16(0)
        central.appendU32(0)
        central.appendU32(0xFFFF_FFFF)
        central.appendU32(0xFFFF_FFFF)
        central.appendU16(UInt16(name.count))
        central.appendU16(UInt16(zip64Extra.count))
        central.appendU16(0)
        central.appendU16(0)
        central.appendU16(0)
        central.appendU32(0)
        central.appendU32(0)
        central.append(name)
        central.append(zip64Extra)

        var eocd = Data()
        eocd.appendU32(Zip.eocdSignature)
        eocd.appendU16(0)
        eocd.appendU16(0)
        eocd.appendU16(1)
        eocd.appendU16(1)
        eocd.appendU32(UInt32(central.count))
        eocd.appendU32(UInt32(local.count))
        eocd.appendU16(0)
        try (local + central + eocd).write(to: url)
    }

    // MARK: - Duplicate names (ADR-012 §5)

    func testDuplicateNamesAreUniquifiedNotOverwritten() throws {
        // Fixture: report.txt twice, REPORT.TXT (case-only), and an
        // NFC/NFD pair of データ.txt — five entries, five files.
        let result = try Unpacker.unpack(
            zipURL: try fixture("hostile-duplicate-names"), options: unpackOptions())
        XCTAssertEqual(result.extractedFiles, 5)
        XCTAssertEqual(result.renamedDuplicates.count, 3,
                       "3 of the 5 entries collide with an earlier one")

        let files = try FileManager.default.contentsOfDirectory(atPath: result.root.path)
        XCTAssertEqual(files.count, 5, "every entry must survive; got \(files)")

        // The first entry keeps the plain name and its original content.
        let first = try String(
            contentsOf: result.root.appendingPathComponent("report.txt"), encoding: .utf8)
        XCTAssertEqual(first, "first\n", "the first entry must not be overwritten by later ones")

        // Every extracted file has distinct content — nothing was clobbered.
        let contents = try files.map {
            try String(contentsOf: result.root.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertEqual(Set(contents).count, 5, "each entry's data must survive: \(contents)")
    }

    // MARK: - Quarantine propagation (ADR-012 §4)

    func testQuarantineIsPropagatedToExtractedFiles() throws {
        let source = workDir.appendingPathComponent("downloaded.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("docs/a.txt", data: Data("A".utf8))
        try writer.addFile("docs/sub/b.txt", data: Data("B".utf8))
        try writer.finalize()

        // Mark the archive the way a browser download would.
        let marker = Data("0083;00000000;Safari;".utf8)
        XCTAssertTrue(XattrUtil.applyQuarantine(marker, to: source))

        let result = try Unpacker.unpack(zipURL: source, options: unpackOptions())
        XCTAssertTrue(result.quarantinePropagated)
        for relative in ["a.txt", "sub/b.txt"] {
            let extracted = result.root.appendingPathComponent(relative)
            XCTAssertEqual(XattrUtil.quarantine(of: extracted), marker,
                           "\(relative) must inherit the archive's quarantine attribute")
        }
    }

    func testQuarantineReachesImplicitlyCreatedDirectories() throws {
        // No directory entries anywhere in this archive: every level below
        // the top is created implicitly on the way to the file. Gatekeeper
        // evaluates the bundle, not the executable inside it, so a `.app`
        // whose root misses the attribute is a Gatekeeper bypass — which is
        // what ADR-012 §4 exists to prevent.
        let source = workDir.appendingPathComponent("bundle.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("Demo.app/Contents/Info.plist", data: Data("<plist/>".utf8))
        try writer.addFile("Demo.app/Contents/MacOS/demo", data: Data("#!/bin/sh\n".utf8))
        try writer.finalize()
        let marker = Data("0083;00000000;Safari;".utf8)
        XCTAssertTrue(XattrUtil.applyQuarantine(marker, to: source))

        let result = try Unpacker.unpack(zipURL: source, options: unpackOptions())
        XCTAssertEqual(result.extractedDirectories, 0, "the archive declares no directory entries")
        XCTAssertEqual(XattrUtil.quarantine(of: result.root), marker,
                       "the bundle root must inherit the archive's quarantine")
        for relative in ["Contents", "Contents/MacOS", "Contents/MacOS/demo"] {
            XCTAssertEqual(XattrUtil.quarantine(of: result.root.appendingPathComponent(relative)),
                           marker, "\(relative) must inherit the archive's quarantine")
        }
    }

    func testUnquarantinedArchiveProducesUnquarantinedFiles() throws {
        let source = workDir.appendingPathComponent("local.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("docs/a.txt", data: Data("A".utf8))
        try writer.finalize()
        let result = try Unpacker.unpack(zipURL: source, options: unpackOptions())
        XCTAssertFalse(result.quarantinePropagated)
        XCTAssertNil(XattrUtil.quarantine(of: result.root.appendingPathComponent("a.txt")))
    }

    func testWrapperFolderInheritsQuarantine() throws {
        let source = workDir.appendingPathComponent("multi.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("a.txt", data: Data("A".utf8))
        try writer.addFile("b.txt", data: Data("B".utf8))
        try writer.finalize()
        let marker = Data("0083;00000000;Safari;".utf8)
        XCTAssertTrue(XattrUtil.applyQuarantine(marker, to: source))

        let result = try Unpacker.unpack(zipURL: source, options: unpackOptions())
        XCTAssertTrue(result.createdWrapper)
        XCTAssertEqual(XattrUtil.quarantine(of: result.root), marker)
    }
}
