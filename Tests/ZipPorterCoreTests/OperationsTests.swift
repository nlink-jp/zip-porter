import XCTest
@testable import ZipPorterCore

final class UnpackerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func makeZip(name: String = "archive.zip",
                         options: ZipWriter.Options = ZipWriter.Options(),
                         _ build: (ZipWriter) throws -> Void) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        let writer = try ZipWriter(url: url, options: options)
        try build(writer)
        try writer.finalize()
        return url
    }

    func testSanitizeRejectsTraversal() {
        XCTAssertNil(Unpacker.sanitize("../evil.txt"))
        XCTAssertNil(Unpacker.sanitize("docs/../../evil.txt"))
        XCTAssertNil(Unpacker.sanitize("/etc/passwd"))
        XCTAssertNil(Unpacker.sanitize("C:\\Windows\\evil.txt"))
        XCTAssertNil(Unpacker.sanitize("file.txt:stream"))
        XCTAssertEqual(Unpacker.sanitize("./docs/a.txt"), ["docs", "a.txt"])
        XCTAssertEqual(Unpacker.sanitize("docs\\sub\\a.txt"), ["docs", "sub", "a.txt"])
    }

    func testSingleTopLevelDirectoryExtractsWithoutWrapper() throws {
        let zip = try makeZip { w in
            try w.addDirectory("docs")
            try w.addFile("docs/a.txt", data: Data("A".utf8))
            try w.addFile("docs/sub/b.txt", data: Data("B".utf8))
        }
        let result = try Unpacker.unpack(zipURL: zip)
        XCTAssertEqual(result.root.lastPathComponent, "docs")
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("sub/b.txt"), encoding: .utf8), "B")
        XCTAssertEqual(result.extractedFiles, 2)
    }

    func testMultipleTopLevelEntriesGetWrapped() throws {
        let zip = try makeZip(name: "報告書.zip") { w in
            try w.addFile("a.txt", data: Data("A".utf8))
            try w.addFile("b.txt", data: Data("B".utf8))
        }
        let result = try Unpacker.unpack(zipURL: zip)
        XCTAssertEqual(result.root.lastPathComponent, "報告書")
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("a.txt"), encoding: .utf8), "A")
    }

    func testCollisionPicksUniqueName() throws {
        try FileManager.default.createDirectory(
            at: workDir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let zip = try makeZip { w in
            try w.addFile("docs/a.txt", data: Data("A".utf8))
        }
        let result = try Unpacker.unpack(zipURL: zip)
        XCTAssertEqual(result.root.lastPathComponent, "docs 2")
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("a.txt"), encoding: .utf8), "A")
    }

    func testZipSlipEntriesAreSkippedNotExtracted() throws {
        // The writer happily records hostile names — sanitization is the
        // extractor's job.
        let zip = try makeZip { w in
            try w.addFile("../evil.txt", data: Data("evil".utf8))
            try w.addFile("good/ok.txt", data: Data("ok".utf8))
        }
        let result = try Unpacker.unpack(zipURL: zip)
        XCTAssertEqual(result.skippedUnsafe, ["../evil.txt"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("ok.txt"), encoding: .utf8), "ok")
    }

    func testFolderPolicyAlwaysWrapsSingleItem() throws {
        let zip = try makeZip(name: "単体.zip") { w in
            try w.addFile("docs/a.txt", data: Data("A".utf8))
        }
        var options = Unpacker.Options()
        options.folderPolicy = .always
        let result = try Unpacker.unpack(zipURL: zip, options: options)
        XCTAssertTrue(result.createdWrapper)
        XCTAssertEqual(result.root.lastPathComponent, "単体")
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("docs/a.txt"), encoding: .utf8), "A")
    }

    func testFolderPolicyNeverExtractsMultipleAtDestination() throws {
        // "b.txt" already exists at the destination — only that top item is
        // renamed; nothing existing is touched, and cleanup of a later
        // failure must never remove the destination itself.
        try Data("existing".utf8).write(to: workDir.appendingPathComponent("b.txt"))
        let zip = try makeZip { w in
            try w.addFile("a.txt", data: Data("A".utf8))
            try w.addFile("b.txt", data: Data("B".utf8))
        }
        var options = Unpacker.Options()
        options.folderPolicy = .never
        let result = try Unpacker.unpack(zipURL: zip, options: options)
        XCTAssertFalse(result.createdWrapper)
        XCTAssertEqual(Set(result.extractedTopItems.map(\.lastPathComponent)), ["a.txt", "b 2.txt"])
        XCTAssertEqual(try String(contentsOf: workDir.appendingPathComponent("b.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: workDir.appendingPathComponent("b 2.txt"), encoding: .utf8), "B")
    }

    func testEncryptedUnpackWithPassword() throws {
        var opts = ZipWriter.Options()
        opts.encryption = .aes256(password: "pw")
        let zip = try makeZip(options: opts) { w in
            try w.addFile("docs/secret.txt", data: Data("S".utf8))
        }
        var unpackOptions = Unpacker.Options()
        unpackOptions.password = "pw"
        let result = try Unpacker.unpack(zipURL: zip, options: unpackOptions)
        XCTAssertEqual(try String(contentsOf: result.root.appendingPathComponent("secret.txt"), encoding: .utf8), "S")
        XCTAssertThrowsError(try Unpacker.unpack(zipURL: zip)) { error in
            XCTAssertEqual(error as? ZipReaderError, .passwordRequired)
        }
        // passwordRequired must fire BEFORE anything is written — a retry
        // with the right password must not land in "docs 2".
        let retried = try Unpacker.unpack(zipURL: zip, options: unpackOptions)
        XCTAssertEqual(retried.root.lastPathComponent, "docs 2",
                       "first successful unpack already created 'docs'; only that may exist")
        let entries = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0.hasPrefix("docs") }.sorted()
        XCTAssertEqual(entries, ["docs", "docs 2"],
                       "the failed passwordless attempt must leave no debris")
    }

    func testModificationTimeIsRestored() throws {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2020, 3, 14, 9, 26, 52)
        let mtime = try XCTUnwrap(Calendar.current.date(from: c))
        let zip = try makeZip { w in
            try w.addFile("docs/t.txt", data: Data("T".utf8), modificationDate: mtime)
        }
        let result = try Unpacker.unpack(zipURL: zip)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: result.root.appendingPathComponent("t.txt").path)
        XCTAssertEqual(attrs[.modificationDate] as? Date, mtime)
    }
}

final class PackerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func write(_ relative: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPackDirectoryFiltersJunkAndRoundTrips() throws {
        // Note: AppleDouble "._*" sidecars can't be tested here — Foundation
        // hides them from directory enumeration entirely, so they never even
        // reach the junk filter when packing. (They still matter on the
        // unpack/inspect side, where foreign ZIPs contain them as entries.)
        _ = try write("プロジェクト/資料.txt", "資料")
        _ = try write("プロジェクト/.DS_Store", "junk")
        _ = try write("プロジェクト/sub/.DS_Store", "junk")
        _ = try write("プロジェクト/sub/データ.csv", "a,b")
        let out = workDir.appendingPathComponent("out.zip")
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("プロジェクト")], output: out)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.skippedJunk.sorted(),
                       ["プロジェクト/.DS_Store", "プロジェクト/sub/.DS_Store"])

        let reader = try ZipReader(url: result.outputURL)
        let names = reader.entries.map { reader.name(of: $0) }.sorted()
        XCTAssertFalse(names.contains { $0.contains(".DS_Store") })
        let doc = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "プロジェクト/資料.txt" })
        XCTAssertEqual(try reader.extractData(doc), Data("資料".utf8))
    }

    func testNoCleanKeepsJunk() throws {
        _ = try write("d/.DS_Store", "junk")
        _ = try write("d/a.txt", "A")
        var options = Packer.Options()
        options.clean = false
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")],
            output: workDir.appendingPathComponent("out.zip"),
            options: options)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertTrue(result.skippedJunk.isEmpty)
    }

    func testSymlinksAreSkipped() throws {
        _ = try write("d/real.txt", "R")
        try FileManager.default.createSymbolicLink(
            at: workDir.appendingPathComponent("d/link.txt"),
            withDestinationURL: workDir.appendingPathComponent("d/real.txt"))
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")],
            output: workDir.appendingPathComponent("out.zip"))
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertEqual(result.skippedSymlinks, ["d/link.txt"])
    }

    func testExistingOutputIsNotOverwritten() throws {
        _ = try write("d/a.txt", "A")
        let out = workDir.appendingPathComponent("out.zip")
        try Data("existing".utf8).write(to: out)
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")], output: out)
        XCTAssertEqual(result.outputURL.lastPathComponent, "out 2.zip")
        XCTAssertEqual(try Data(contentsOf: out), Data("existing".utf8))
    }

    func testMultipleInputsLandAtRoot() throws {
        let a = try write("x/a.txt", "A")
        let b = try write("y/b.txt", "B")
        let result = try Packer.pack(
            inputs: [a, b], output: workDir.appendingPathComponent("multi.zip"))
        let reader = try ZipReader(url: result.outputURL)
        XCTAssertEqual(reader.entries.map { reader.name(of: $0) }.sorted(), ["a.txt", "b.txt"])
    }

    func testMissingInputThrows() {
        XCTAssertThrowsError(try Packer.pack(
            inputs: [workDir.appendingPathComponent("nope")],
            output: workDir.appendingPathComponent("out.zip"))) { error in
            guard case .inputNotFound = error as? Packer.Failure else {
                return XCTFail("expected inputNotFound, got \(error)")
            }
        }
    }

    func testCancellationRemovesPartialOutput() throws {
        _ = try write("d/a.txt", "A")
        _ = try write("d/b.txt", "B")
        var calls = 0
        XCTAssertThrowsError(try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")],
            output: workDir.appendingPathComponent("out.zip"),
            shouldCancel: { calls += 1; return calls > 2 })) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("out.zip").path))
    }

    func testUnpackCancellationRemovesTree() throws {
        _ = try write("d/a.txt", "A")
        _ = try write("d/b.txt", "B")
        let packed = try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")],
            output: workDir.appendingPathComponent("out.zip"))
        let dest = workDir.appendingPathComponent("dest")
        var options = Unpacker.Options()
        options.destination = dest
        XCTAssertThrowsError(try Unpacker.unpack(
            zipURL: packed.outputURL, options: options,
            shouldCancel: { true })) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("d").path))
    }

    func testPackedEmptyDirectorySurvivesRoundTrip() throws {
        try FileManager.default.createDirectory(
            at: workDir.appendingPathComponent("d/空フォルダ"), withIntermediateDirectories: true)
        _ = try write("d/a.txt", "A")
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")],
            output: workDir.appendingPathComponent("out.zip"))
        let dest = workDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var options = Unpacker.Options()
        options.destination = dest
        let unpacked = try Unpacker.unpack(zipURL: result.outputURL, options: options)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: unpacked.root.appendingPathComponent("空フォルダ").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
