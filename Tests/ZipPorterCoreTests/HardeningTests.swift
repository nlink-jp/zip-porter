import XCTest
@testable import ZipPorterCore

/// ADR-0001 hardening, exercised against hostile archives built straight
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

    // MARK: - Decompression bombs (ADR-0001 §1)

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

    // MARK: - Overlapping entries (ADR-0001 §3)

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

    // The range class (ADR-0005): the check and the read must derive the
    // payload position from the same header. These fixtures look disjoint
    // from the central directory and coincide in the local headers.

    func testOverlapHiddenInALocalExtraFieldIsRejectedAtOpen() throws {
        // Entry b's local header sits inside entry a's 32-byte extra field;
        // central-directory arithmetic sees [0,32) and [32,64), while both
        // payloads start at byte 63.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-overlap-local-extra"))) { error in
            XCTAssertEqual(error as? ZipReaderError, .overlappingEntries)
        }
    }

    func testOverlapHiddenInALocalNameLengthIsRejectedAtOpen() throws {
        // Same shape, carried by a local name length (33) that disagrees
        // with the central directory's (1).
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-overlap-local-name"))) { error in
            XCTAssertEqual(error as? ZipReaderError, .overlappingEntries)
        }
    }

    func testLocalExtraFieldPushingDataPastEOFIsRejectedAtOpen() throws {
        // The central directory is consistent with the file; only the local
        // extra length (1000 bytes that are not there) is hostile. Rejection
        // must happen at open, not as a truncated read mid-extraction.
        XCTAssertThrowsError(try ZipReader(url: try fixture("hostile-extra-past-eof"))) { error in
            guard case .corrupt = error as? ZipReaderError else {
                return XCTFail("expected corrupt, got \(error)")
            }
        }
    }

    func testDataOffsetsAreResolvedFromTheLocalHeader() throws {
        // Our own writer puts a 20-byte ZIP64 extra field in the local
        // header when forced; the resolved offset must account for it and
        // extraction must read from exactly there.
        let url = workDir.appendingPathComponent("z64.zip")
        let writer = try ZipWriter(url: url)
        writer.zip64Threshold = 100
        let payload = Data((0..<5000).map { UInt8($0 % 256) })
        try writer.addFile("big.bin", data: payload)
        try writer.finalize()
        let reader = try ZipReader(url: url)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.dataOffset, entry.localHeaderOffset + 30 + 7 + 20,
                       "30-byte header + \"big.bin\" + ZIP64 extra (4 + 16)")
        XCTAssertEqual(try reader.extractData(entry), payload)
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

    // MARK: - Space budget (ADR-0001 §2)

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

    func testFreeSpaceOnNetworkVolumeFallsBackToStatfsFigure() {
        // SMB mounts report 0 for the important-usage key while statfs
        // knows the real figure — the 0 must not read as a full disk.
        XCTAssertEqual(
            Unpacker.resolveFreeSpace(importantUsage: 0, plain: 3_275_891_720_192),
            3_275_891_720_192)
        XCTAssertEqual(Unpacker.resolveFreeSpace(importantUsage: nil, plain: 500), 500)
    }

    func testFreeSpacePrefersTheLargerPurgeableAwareFigure() {
        // On local APFS the important-usage key counts purgeable space, so
        // it can exceed statfs; the budget should use the real headroom.
        XCTAssertEqual(Unpacker.resolveFreeSpace(importantUsage: 1000, plain: 700), 1000)
    }

    func testFreeSpaceOnGenuinelyFullDiskStillReadsAsZero() {
        // Both sources agreeing on ~0 is a real full disk, not a network
        // artifact — the refusal must survive the fallback.
        XCTAssertEqual(Unpacker.resolveFreeSpace(importantUsage: 0, plain: 0), 0)
    }

    func testFreeSpaceWithNoUsableSourceIsUnknown() {
        // Unknown disables the budget check rather than fabricating a figure.
        XCTAssertNil(Unpacker.resolveFreeSpace(importantUsage: nil, plain: nil))
        XCTAssertNil(Unpacker.resolveFreeSpace(importantUsage: 0, plain: nil))
        XCTAssertNil(Unpacker.resolveFreeSpace(importantUsage: -5, plain: nil))
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

    // MARK: - Duplicate names (ADR-0001 §5)

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

    // MARK: - Never overwrite

    func testExclusiveCreationRefusesAnExistingFile() throws {
        // The "never overwrite" rule rests on this: FileManager.createFile
        // truncates whatever it finds, so the guarantee would only be as
        // good as the gap between the existence check and the write.
        let url = workDir.appendingPathComponent("taken.bin")
        try Data("original".utf8).write(to: url)
        XCTAssertThrowsError(try PathUtil.createExclusively(at: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8),
                       "the existing file must be left exactly as it was")

        let fresh = workDir.appendingPathComponent("free.bin")
        let handle = try PathUtil.createExclusively(at: fresh)
        try handle.write(contentsOf: Data("new".utf8))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: fresh), Data("new".utf8))
    }

    func testExclusiveDirectoryCreationRefusesAnythingAtThePath() throws {
        // `createDirectory(withIntermediateDirectories: true)` calls an
        // existing directory a success; the top-level claim needs the
        // opposite — success only when this call made the directory.
        let taken = workDir.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PathUtil.createDirectoryExclusively(at: taken)) { error in
            XCTAssertEqual((error as NSError).code, Int(EEXIST), "\(error)")
        }

        let file = workDir.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try PathUtil.createDirectoryExclusively(at: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))

        // A dangling symlink is invisible to `fileExists` (which follows
        // links) and must still refuse.
        let dangling = workDir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling,
                                                   withDestinationURL: workDir.appendingPathComponent("nowhere"))
        XCTAssertThrowsError(try PathUtil.createDirectoryExclusively(at: dangling))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path),
                       workDir.appendingPathComponent("nowhere").path)

        let fresh = workDir.appendingPathComponent("fresh")
        try PathUtil.createDirectoryExclusively(at: fresh)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Failure removes only what this extraction created (ADR-0005)
    //
    // The ownership class: cleanup consults what an exclusive create
    // actually returned, never the list of names that were planned. The
    // progress callback fires before each entry's create, which is where a
    // competing writer is interposed below.

    func testFailedExtractionLeavesAFileAnotherWriterCreatedAlone() throws {
        // The name was free when it was chosen; another writer took it
        // before the exclusive create. The create fails — and the file that
        // made it fail is not ours to delete.
        let source = workDir.appendingPathComponent("one.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("report.txt", data: Data("ours\n".utf8))
        try writer.finalize()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let theirs = dest.appendingPathComponent("report.txt")
        var options = Unpacker.Options()
        options.destination = dest

        var interposed = false
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: source, options: options, progress: { _ in
            guard !interposed else { return }
            interposed = true
            try? Data("theirs\n".utf8).write(to: theirs)
        })) { error in
            XCTAssertEqual((error as NSError).code, Int(EEXIST), "\(error)")
        }
        XCTAssertTrue(interposed)
        XCTAssertEqual(try Data(contentsOf: theirs), Data("theirs\n".utf8),
                       "the other writer's file must survive the failed extraction untouched")
    }

    func testDanglingSymlinkAtAPlannedNameIsTreatedAsTaken() throws {
        // `fileExists` follows symlinks and calls a dangling one absent, so
        // the uniqueness check would pick the name and the exclusive create
        // would then fail on it — and the old cleanup deleted the link. The
        // check now uses lstat semantics: the name is taken, the entry lands
        // on "report 2.txt", the link is not touched.
        let source = workDir.appendingPathComponent("one.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("report.txt", data: Data("ours\n".utf8))
        try writer.finalize()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let link = dest.appendingPathComponent("report.txt")
        let nowhere = dest.appendingPathComponent("nowhere-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nowhere)
        var options = Unpacker.Options()
        options.destination = dest

        let result = try Unpacker.unpack(zipURL: source, options: options)
        XCTAssertEqual(result.root.lastPathComponent, "report 2.txt")
        XCTAssertEqual(try Data(contentsOf: result.root), Data("ours\n".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       nowhere.path, "the pre-existing symlink must survive")
    }

    func testTopLevelFoldersAreClaimedBeforeTheFirstByteIsWritten() throws {
        // The window between the uniqueness check and the claim must not
        // span the extraction: every top-level folder exists — created by
        // us — when the first entry's progress callback fires.
        let source = workDir.appendingPathComponent("two.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("alpha/a.txt", data: Data("A".utf8))
        try writer.addFile("beta/b.txt", data: Data("B".utf8))
        try writer.addFile("gamma", data: Data("G".utf8))
        try writer.finalize()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var options = Unpacker.Options()
        options.destination = dest
        options.folderPolicy = .never

        var seenAtFirstCallback: [String]?
        _ = try Unpacker.unpack(zipURL: source, options: options, progress: { _ in
            if seenAtFirstCallback == nil {
                seenAtFirstCallback = try? FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
            }
        })
        XCTAssertEqual(seenAtFirstCallback, ["alpha", "beta"],
                       "folders are claimed up front; the top-level file is claimed by its own create")
    }

    func testFailedExtractionRemovesOnlyTheTopLevelItemsItCreated() throws {
        // Two top-level files extracted straight into the destination.
        // Another writer creates the second one after the first has been
        // extracted. The first is ours and goes; the second is theirs and
        // stays with its content.
        let source = workDir.appendingPathComponent("two.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("a.txt", data: Data("A".utf8))
        try writer.addFile("b.txt", data: Data("B".utf8))
        try writer.finalize()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var options = Unpacker.Options()
        options.destination = dest
        options.folderPolicy = .never
        let theirs = dest.appendingPathComponent("b.txt")

        var interposed = false
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: source, options: options, progress: { p in
            guard p.currentPath == "b.txt", !interposed else { return }
            interposed = true
            try? Data("theirs".utf8).write(to: theirs)
        })) { error in
            XCTAssertEqual((error as NSError).code, Int(EEXIST), "\(error)")
        }
        XCTAssertTrue(interposed)
        XCTAssertEqual(try Data(contentsOf: theirs), Data("theirs".utf8),
                       "the other writer's file must survive")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["b.txt"],
                       "our own a.txt must be removed; nothing else may remain")
    }

    func testFailureMidEntryRemovesThePartialFileThroughTheLedger() throws {
        // The only remover is the ledger, so a partial file must go with its
        // owned top-level item under every folder policy: the wrapper, the
        // adopted top-level file itself, or the claimed folder above it.
        let bomb = try fixture("hostile-size-lie") // one top-level file, bomb.bin

        var wrapped = unpackOptions()
        wrapped.folderPolicy = .always
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: bomb, options: wrapped))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path), [],
                       "the wrapper and the partial file inside it must go")

        var flat = unpackOptions()
        flat.folderPolicy = .never
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: bomb, options: flat))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path), [],
                       "the adopted top-level file must go")

        // Nested under `.never`: a second entry whose deflate stream is
        // damaged fails mid-entry, after `d/` and `d/first.txt` were written.
        let source = workDir.appendingPathComponent("nested.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("d/first.txt", data: Data("first\n".utf8))
        try writer.addFile("d/second.txt", data: Data(String(repeating: "second line of text\n", count: 100).utf8))
        try writer.finalize()
        let reader = try ZipReader(url: source)
        let second = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/second.txt" })
        let handle = try FileHandle(forUpdating: source)
        try handle.seek(toOffset: second.dataOffset + 4)
        try handle.write(contentsOf: Data([0xFF, 0x00, 0xFF, 0x00]))
        try handle.close()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var nested = Unpacker.Options()
        nested.destination = dest
        nested.folderPolicy = .never
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: source, options: nested))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [],
                       "the claimed folder, with the finished and the partial file, must go")
    }

    func testCaseVariantTopLevelFoldersAreKeptApartUnderNever() throws {
        // A case-sensitive system can ship `Docs/` and `docs/`; on the
        // default case-insensitive volume the second exclusive mkdir would
        // hit the first. Top-level names are uniquified on the same folded
        // key files use, so both land — side by side, nothing merged.
        let source = workDir.appendingPathComponent("case.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("Docs/a.txt", data: Data("A".utf8))
        try writer.addFile("docs/b.txt", data: Data("B".utf8))
        try writer.finalize()
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var options = Unpacker.Options()
        options.destination = dest
        options.folderPolicy = .never

        let result = try Unpacker.unpack(zipURL: source, options: options)
        XCTAssertEqual(result.extractedFiles, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted(),
                       ["Docs", "docs 2"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Docs/a.txt")), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("docs 2/b.txt")), Data("B".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("Docs").path),
                       ["a.txt"], "nothing from docs/ may land in Docs/")
    }

    // MARK: - Local headers are read through right-sized windows (ADR-0005)

    /// A stored archive built byte by byte, so entry sizes place the local
    /// headers exactly where the test wants them.
    private func storedArchive(_ entries: [(name: String, data: Data)]) -> Data {
        var body = Data()
        var central = Data()
        for (name, payload) in entries {
            let nameBytes = Data(name.utf8)
            var crc = CRC32()
            crc.update(payload)
            let offset = UInt32(body.count)
            var local = Data()
            local.appendU32(Zip.localHeaderSignature)
            local.appendU16(20)
            local.appendU16(0)
            local.appendU16(0) // store
            local.appendU16(0)
            local.appendU16(0)
            local.appendU32(crc.value)
            local.appendU32(UInt32(payload.count))
            local.appendU32(UInt32(payload.count))
            local.appendU16(UInt16(nameBytes.count))
            local.appendU16(0)
            local.append(nameBytes)
            body.append(local)
            body.append(payload)

            var header = Data()
            header.appendU32(Zip.centralHeaderSignature)
            header.appendU16(20)
            header.appendU16(20)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU32(crc.value)
            header.appendU32(UInt32(payload.count))
            header.appendU32(UInt32(payload.count))
            header.appendU16(UInt16(nameBytes.count))
            header.appendU16(0)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU16(0)
            header.appendU32(0)
            header.appendU32(offset)
            header.append(nameBytes)
            central.append(header)
        }
        var eocd = Data()
        eocd.appendU32(Zip.eocdSignature)
        eocd.appendU16(0)
        eocd.appendU16(0)
        eocd.appendU16(UInt16(entries.count))
        eocd.appendU16(UInt16(entries.count))
        eocd.appendU32(UInt32(central.count))
        eocd.appendU32(UInt32(body.count))
        eocd.appendU16(0)
        return body + central + eocd
    }

    func testLocalHeadersAreReadThroughWindowsSizedToTheHeadersAhead() throws {
        // 300 small entries (~40 KiB of archive) share one window, which
        // also reaches the first big entry's header 40 KiB in; the two
        // remaining 300 KiB entries lie farther apart than a window and cost
        // one small read apiece — never a 256 KiB window each. Every offset
        // must still be right.
        var entries: [(name: String, data: Data)] = []
        for i in 0..<300 {
            entries.append(("s\(i)", TestSupport.symbols(100, seed: UInt64(1000 + i))))
        }
        for i in 0..<3 {
            entries.append(("big\(i)", TestSupport.noise(300 << 10, seed: UInt64(2000 + i))))
        }
        let url = workDir.appendingPathComponent("windows.zip")
        try storedArchive(entries).write(to: url)

        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.count, 303)
        XCTAssertEqual(reader.localHeaderReads, 3,
                       "one window for the dense run plus the first big header, one read per remaining sparse header")
        for (entry, (name, data)) in zip(reader.entries, entries) {
            XCTAssertEqual(entry.dataOffset, entry.localHeaderOffset + 30 + UInt64(name.utf8.count), name)
            XCTAssertEqual(try reader.extractData(entry), data, name)
        }
    }

    func testSuccessfulExtractionStillReportsEveryTopLevelItem() throws {
        // The ledger changes what failure removes, not what success reports.
        let source = workDir.appendingPathComponent("two.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("alpha/a.txt", data: Data("A".utf8))
        try writer.addFile("beta", data: Data("B".utf8))
        try writer.finalize()
        var options = Unpacker.Options()
        options.destination = workDir
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: source, options: options)
        XCTAssertEqual(result.extractedTopItems.map(\.lastPathComponent).sorted(), ["alpha", "beta"])
        XCTAssertEqual(try Data(contentsOf: workDir.appendingPathComponent("alpha/a.txt")), Data("A".utf8))
        XCTAssertEqual(try Data(contentsOf: workDir.appendingPathComponent("beta")), Data("B".utf8))
    }

    func testEntriesWithoutAUnixModeGetTheUsualDefault() throws {
        // A DOS-host archive declares no mode; extraction must still land on
        // the ordinary umask default rather than the mode the file happened
        // to be created with.
        let result = try Unpacker.unpack(zipURL: try fixture("cp932"), options: unpackOptions())
        let first = try XCTUnwrap(
            FileManager.default.enumerator(at: result.root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
        let mode = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber)?
                .uint16Value)
        XCTAssertEqual(mode, UInt16(0o666) & ~PosixPermissions.umask,
                       "got \(String(mode, radix: 8)) for \(first.lastPathComponent)")
    }

    // MARK: - Permission bits

    func testArchiveModesAreMaskedByTheUmask() throws {
        // The fixture asks for 0777 and 0666. Whatever the umask on the
        // machine running this, nothing group- or world-writable may land.
        let result = try Unpacker.unpack(zipURL: try fixture("hostile-world-writable"),
                                         options: unpackOptions())
        for (name, requested) in [("tool.sh", UInt16(0o777)), ("secret.txt", UInt16(0o666))] {
            let path = result.root.appendingPathComponent(name).path
            let mode = try XCTUnwrap(
                (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
                    .uint16Value)
            XCTAssertEqual(mode, PosixPermissions.extracted(mode: requested, isDirectory: false),
                           "\(name): got \(String(mode, radix: 8))")
            XCTAssertEqual(mode & UInt16(0o022), 0,
                           "\(name) must not be group- or world-writable")
        }
    }

    // MARK: - Quarantine propagation (ADR-0001 §4)

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
        // what ADR-0001 §4 exists to prevent.
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

    func testQuarantineFailuresAreReportedNotSwallowed() throws {
        let source = workDir.appendingPathComponent("downloaded.zip")
        let writer = try ZipWriter(url: source)
        try writer.addFile("docs/a.txt", data: Data("A".utf8))
        try writer.finalize()
        XCTAssertTrue(XattrUtil.applyQuarantine(Data("0083;00000000;Safari;".utf8), to: source))

        // Deny extended-attribute writes on the destination, inherited by
        // everything created inside it — the same shape as extracting onto
        // a volume that cannot carry xattrs.
        let dest = workDir.appendingPathComponent("no-xattr")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try XCTSkipUnless(denyExtendedAttributeWrites(at: dest), "could not apply the deny ACL")

        var options = Unpacker.Options()
        options.destination = dest
        let result = try Unpacker.unpack(zipURL: source, options: options)

        XCTAssertFalse(result.quarantinePropagated,
                       "propagation must not be claimed when the attribute would not take")
        XCTAssertTrue(result.quarantineFailures.contains("docs/a.txt"),
                      "the failed item must be named: \(result.quarantineFailures)")
        XCTAssertTrue(result.quarantineFailures.contains("docs"),
                      "directories count too: \(result.quarantineFailures)")
    }

    /// `chmod +a` with inheritance: the cheapest way to make `setxattr`
    /// fail on files this process owns.
    private func denyExtendedAttributeWrites(at url: URL) -> Bool {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a",
                           "\(NSUserName()) deny writeextattr,file_inherit,directory_inherit",
                           url.path]
        do { try chmod.run() } catch { return false }
        chmod.waitUntilExit()
        return chmod.terminationStatus == 0
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
