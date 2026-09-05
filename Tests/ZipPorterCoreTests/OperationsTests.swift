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

    private func writeData(_ relative: String, _ data: Data) throws -> URL {
        let url = workDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
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

    // MARK: - Parallel compression (ADR-0002)

    /// Text that deflates well, so the probe keeps these on the deflate path.
    private func compressibleData(_ seed: Int, count: Int) -> Data {
        var text = ""
        var value = seed
        while text.utf8.count < count {
            value = (value &* 1103515245 &+ 12345) & 0x7FFF_FFFF
            text += "line \(value % 97) alpha beta gamma データ 日本語\n"
        }
        return Data(text.utf8)
    }

    func testParallelPackRoundTripsManyEntries() throws {
        // Enough entries to actually run concurrently, with distinct
        // contents so a mixed-up result cannot pass.
        for i in 0..<60 {
            _ = try writeData("many/file\(i).txt", compressibleData(i, count: 40_000))
        }
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("many")],
            output: workDir.appendingPathComponent("many.zip"))
        XCTAssertEqual(result.fileCount, 60)

        let reader = try ZipReader(url: result.outputURL)
        for i in 0..<60 {
            let entry = try XCTUnwrap(reader.entries.first {
                reader.name(of: $0) == "many/file\(i).txt"
            }, "entry \(i) missing")
            XCTAssertEqual(try reader.extractData(entry), compressibleData(i, count: 40_000),
                           "entry \(i) has the wrong bytes")
            XCTAssertEqual(entry.method, .deflate)
        }
    }

    func testParallelPackIsDeterministic() throws {
        for i in 0..<30 {
            _ = try writeData("d/file\(i).txt", compressibleData(i, count: 20_000))
        }
        let first = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                    output: workDir.appendingPathComponent("a.zip"))
        let second = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("b.zip"))
        XCTAssertEqual(try Data(contentsOf: first.outputURL),
                       try Data(contentsOf: second.outputURL),
                       "concurrent compression must not change the bytes written")
    }

    func testParallelPackWithEncryptionRoundTrips() throws {
        for i in 0..<20 {
            _ = try writeData("d/file\(i).txt", compressibleData(i, count: 30_000))
        }
        var options = Packer.Options()
        options.encryption = .aes256(password: "pw")
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("enc.zip"),
                                     options: options)
        let reader = try ZipReader(url: result.outputURL)
        let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/file7.txt" })
        XCTAssertEqual(try reader.extractData(entry, password: "pw"),
                       compressibleData(7, count: 30_000))
    }

    func testIncompressibleDataIsStoredNotDeflated() throws {
        var random = SystemRandomNumberGenerator()
        let noise = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255, using: &random) })
        _ = try writeData("d/noise.bin", noise)
        _ = try writeData("d/text.txt", compressibleData(1, count: 200_000))
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("mixed.zip"))
        let reader = try ZipReader(url: result.outputURL)
        let noiseEntry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/noise.bin" })
        let textEntry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/text.txt" })
        XCTAssertEqual(noiseEntry.method, .store, "random data must not be deflated")
        XCTAssertEqual(noiseEntry.compressedSize, UInt64(noise.count),
                       "stored data carries no deflate framing")
        XCTAssertEqual(textEntry.method, .deflate, "compressible data must still deflate")
        XCTAssertEqual(try reader.extractData(noiseEntry), noise)
    }

    func testSpilledEntryRoundTrips() throws {
        // Forces the scratch-file path: compressed output above the spill
        // threshold cannot stay in memory.
        let big = compressibleData(3, count: 40 << 20)
        _ = try writeData("d/big.txt", big)
        _ = try writeData("d/small.txt", compressibleData(4, count: 1000))
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("spill.zip"))
        let reader = try ZipReader(url: result.outputURL)
        let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/big.txt" })
        XCTAssertEqual(try reader.extractData(entry), big)
        // The scratch arena must not survive the pack.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
            .filter { $0.contains("zp-scratch") }
        XCTAssertEqual(leftovers, [])
    }

    func testBlockParallelSingleLargeFileRoundTrips() throws {
        // Force the ADR-0003 path with test-sized data: 5 MB across several
        // sub-blockSize... actually sub-threshold blocks. The joined stream
        // (sync-flushed blocks + empty final block) must inflate to the
        // exact original everywhere.
        let saved = ParallelCompressor.blockParallelThreshold
        ParallelCompressor.blockParallelThreshold = 1 << 20
        defer { ParallelCompressor.blockParallelThreshold = saved }

        let big = compressibleData(9, count: 5 << 20)
        _ = try writeData("d/model.bin", big)
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("big.zip"))
        let reader = try ZipReader(url: result.outputURL)
        let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/model.bin" })
        XCTAssertEqual(entry.method, .deflate)
        XCTAssertEqual(try reader.extractData(entry), big,
                       "block-joined deflate stream must inflate to the original")
    }

    func testBlockParallelIsDeterministicAndExternalToolsAccept() throws {
        let saved = ParallelCompressor.blockParallelThreshold
        ParallelCompressor.blockParallelThreshold = 1 << 20
        defer { ParallelCompressor.blockParallelThreshold = saved }

        let big = compressibleData(11, count: 4 << 20)
        _ = try writeData("d/big.txt", big)
        let a = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                output: workDir.appendingPathComponent("a.zip"))
        let b = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                output: workDir.appendingPathComponent("b.zip"))
        XCTAssertEqual(try Data(contentsOf: a.outputURL), try Data(contentsOf: b.outputURL))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-t", a.outputURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0,
                       "unzip -t must accept the block-joined stream: \(out)")
    }

    func testBlockParallelExactMultipleOfWaveRoundTrips() throws {
        // File length an exact multiple of the block size: the trailing
        // empty Z_FINISH block is the only thing carrying BFINAL.
        let saved = ParallelCompressor.blockParallelThreshold
        ParallelCompressor.blockParallelThreshold = 1 << 20
        defer { ParallelCompressor.blockParallelThreshold = saved }

        var exact = compressibleData(13, count: ParallelCompressor.blockSize)
        exact.removeSubrange(ParallelCompressor.blockSize..<exact.count)
        XCTAssertEqual(exact.count, ParallelCompressor.blockSize)
        _ = try writeData("d/exact.bin", exact)
        let result = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("exact.zip"))
        let reader = try ZipReader(url: result.outputURL)
        let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "d/exact.bin" })
        XCTAssertEqual(try reader.extractData(entry), exact)
    }

    func testProgressReachesTotalAndIsMonotonic() throws {
        for i in 0..<10 {
            _ = try writeData("d/f\(i).txt", compressibleData(i, count: 50_000))
        }
        var random = SystemRandomNumberGenerator()
        _ = try writeData("d/noise.bin",
                          Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &random) }))
        var seen: [OperationProgress] = []
        _ = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                            output: workDir.appendingPathComponent("p.zip"),
                            progress: { seen.append($0) })
        let last = try XCTUnwrap(seen.last)
        XCTAssertEqual(last.processedBytes, last.totalBytes,
                       "all bytes must be accounted for (deflated and stored alike)")
        XCTAssertGreaterThan(last.totalBytes, 0)
        for pair in zip(seen, seen.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.processedBytes, pair.1.processedBytes,
                                     "progress must never move backwards")
        }
    }

    func testUnpackProgressReachesDeclaredTotal() throws {
        for i in 0..<5 {
            _ = try writeData("d/f\(i).txt", compressibleData(i, count: 30_000))
        }
        let packed = try Packer.pack(inputs: [workDir.appendingPathComponent("d")],
                                     output: workDir.appendingPathComponent("p.zip"))
        var last: OperationProgress?
        var unpackOptions = Unpacker.Options()
        unpackOptions.destination = workDir.appendingPathComponent("out")
        _ = try Unpacker.unpack(zipURL: packed.outputURL, options: unpackOptions,
                                progress: { last = $0 })
        let final = try XCTUnwrap(last)
        XCTAssertEqual(final.processedBytes, final.totalBytes)
        // compressibleData generates at least `count` bytes per file.
        XCTAssertGreaterThanOrEqual(final.totalBytes, UInt64(5 * 30_000))
    }

    func testPartFileNeverSurvivesSuccessOrFailure() throws {
        _ = try write("d/a.txt", "A")
        let out = workDir.appendingPathComponent("out.zip")
        _ = try Packer.pack(inputs: [workDir.appendingPathComponent("d")], output: out)
        var names = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertTrue(names.contains("out.zip"))
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") },
                       "the temporary name must be renamed away on success")

        // Cancellation: the .part must be cleaned up and no .zip appear.
        _ = try write("e/b.txt", "B")
        _ = try write("e/c.txt", "C")
        var calls = 0
        XCTAssertThrowsError(try Packer.pack(
            inputs: [workDir.appendingPathComponent("e")],
            output: workDir.appendingPathComponent("cancelled.zip"),
            shouldCancel: { calls += 1; return calls > 1 }))
        names = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        XCTAssertFalse(names.contains("cancelled.zip"))
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") },
                       "a failed pack must remove its temporary file")
    }

    func testOverwriteReplacesTheChosenPath() throws {
        // The save panel already asked the user about replacing, so the
        // numbered-name policy must step aside for that one path.
        _ = try write("d/a.txt", "A")
        let out = workDir.appendingPathComponent("out.zip")
        try Data("existing".utf8).write(to: out)
        var options = Packer.Options()
        options.overwrite = true
        let result = try Packer.pack(
            inputs: [workDir.appendingPathComponent("d")], output: out, options: options)
        XCTAssertEqual(result.outputURL, out)
        XCTAssertNotEqual(try Data(contentsOf: out), Data("existing".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("out 2.zip").path))
        let reader = try ZipReader(url: out)
        XCTAssertEqual(reader.entries.map { reader.name(of: $0) }.sorted(), ["d/", "d/a.txt"])
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
