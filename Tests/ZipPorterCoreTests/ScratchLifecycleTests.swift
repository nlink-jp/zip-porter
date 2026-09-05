import XCTest
@testable import ZipPorterCore

/// ADR-0005 for the parallel compressor: class A (the scratch arena is owned
/// by the compress call from creation to cleanUp, whatever fails) and class
/// C (finished results share an aggregate memory budget). Write failures are
/// injected through `Limits.openScratch`; the real filesystem never fails on
/// cue.
final class ScratchLifecycleTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    /// Small limits so the spill path runs on kilobytes, not megabytes.
    private func limits(spill: Int = 64 << 10,
                        budget: Int = .max,
                        open: ((URL) throws -> ScratchFile)? = nil) -> ParallelCompressor.Limits {
        var limits = ParallelCompressor.Limits()
        limits.spillThreshold = spill
        limits.memoryBudget = budget
        if let open { limits.openScratch = open }
        return limits
    }

    /// Incompressible bytes: deflate output ≈ input size.
    private func noise(_ count: Int, seed: UInt64) -> Data {
        var x = seed | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<count {
                x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[i] = UInt8(truncatingIfNeeded: x >> 33)
            }
        }
        return data
    }

    /// Sixteen-symbol text: deflates to roughly half, so the probe says
    /// "worth it" and the output stays below a 64 KiB threshold for inputs
    /// under ~120 KiB.
    private func symbols(_ count: Int, seed: UInt64) -> Data {
        var x = seed | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<count {
                x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[i] = UInt8(ascii: "a") + UInt8(truncatingIfNeeded: (x >> 33) & 15)
            }
        }
        return data
    }

    private func input(_ name: String, _ data: Data) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func scratchLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workDir.path).filter { $0.contains("zp-scratch") }
    }

    private func inflate(_ result: ParallelCompressor.Result) throws -> Data {
        var compressed = Data()
        let next = try result.open()
        while let chunk = try next() { compressed.append(chunk) }
        var out = Data()
        try DeflateStream(.decompress).process(compressed, final: true) { out.append($0) }
        return out
    }

    /// A real file on disk whose writes and/or close fail on cue.
    final class FailingScratch: ScratchFile {
        let handle: FileHandle
        var writesBeforeFailure: Int
        let failClose: Bool

        init(handle: FileHandle, writesBeforeFailure: Int, failClose: Bool) {
            self.handle = handle
            self.writesBeforeFailure = writesBeforeFailure
            self.failClose = failClose
        }

        func write(contentsOf data: Data) throws {
            guard writesBeforeFailure > 0 else {
                // Half the bytes land, then the error — the shape of ENOSPC.
                try handle.write(contentsOf: data.prefix(data.count / 2))
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
            writesBeforeFailure -= 1
            try handle.write(contentsOf: data)
        }

        func close() throws {
            try handle.close()
            if failClose { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        }
    }

    private func failing(afterWrites count: Int, failClose: Bool = false) -> (URL) throws -> ScratchFile {
        { url in
            FailingScratch(handle: try PathUtil.createExclusively(at: url),
                           writesBeforeFailure: count, failClose: failClose)
        }
    }

    // MARK: - Class A: one arena, owned from creation to cleanUp

    func testArenaIsCreatedOnFirstSpillHiddenAndRemovedByCleanUp() throws {
        let small = try input("s.bin", noise(1000, seed: 1))
        let quiet = try ParallelCompressor.compress([small], deflate: [true],
                                                    scratchDirectory: workDir, limits: limits())
        XCTAssertFalse(quiet.arena.exists, "nothing spilled, nothing created")
        XCTAssertEqual(try scratchLeftovers(), [])
        quiet.cleanUp()

        let big = try input("b.bin", noise(256 << 10, seed: 2))
        let output = try ParallelCompressor.compress([big], deflate: [true],
                                                     scratchDirectory: workDir, limits: limits())
        XCTAssertTrue(output.arena.exists)
        let names = try scratchLeftovers()
        XCTAssertEqual(names.count, 1, "one arena per pack: \(names)")
        XCTAssertTrue(names[0].hasPrefix("."), "hidden from Finder while it lives")
        XCTAssertEqual(try inflate(try XCTUnwrap(output.results[0])), noise(256 << 10, seed: 2))
        output.cleanUp()
        XCTAssertEqual(try scratchLeftovers(), [])
        output.cleanUp() // idempotent
    }

    func testArenaIsRemovedWhenItsFirstWriteFails() throws {
        // The write that fails is the one that would have made the file
        // known under the old per-entry design.
        let url = try input("a.bin", noise(256 << 10, seed: 3))
        XCTAssertThrowsError(try ParallelCompressor.compress(
            [url], deflate: [true], scratchDirectory: workDir,
            limits: limits(open: failing(afterWrites: 0))))
        XCTAssertEqual(try scratchLeftovers(), [], "a half-written arena must not survive the failure")
    }

    func testArenaIsRemovedWhenALaterWriteFails() throws {
        let url = try input("a.bin", noise(1 << 20, seed: 4))
        XCTAssertThrowsError(try ParallelCompressor.compress(
            [url], deflate: [true], scratchDirectory: workDir,
            limits: limits(open: failing(afterWrites: 2))))
        XCTAssertEqual(try scratchLeftovers(), [])
    }

    func testArenaIsRemovedEvenWhenItsCloseFails() throws {
        let url = try input("a.bin", noise(256 << 10, seed: 5))
        let output = try ParallelCompressor.compress(
            [url], deflate: [true], scratchDirectory: workDir,
            limits: limits(open: failing(afterWrites: .max, failClose: true)))
        XCTAssertEqual(try scratchLeftovers().count, 1)
        output.cleanUp()
        XCTAssertEqual(try scratchLeftovers(), [], "a failing close must not keep the file alive")
    }

    func testArenaIsRemovedWhenBlockParallelCompressionFailsToWrite() throws {
        let saved = ParallelCompressor.blockParallelThreshold
        ParallelCompressor.blockParallelThreshold = 1 << 10
        defer { ParallelCompressor.blockParallelThreshold = saved }
        let url = try input("big.bin", noise(512 << 10, seed: 6))
        XCTAssertThrowsError(try ParallelCompressor.compress(
            [url], deflate: [true], scratchDirectory: workDir,
            limits: limits(open: failing(afterWrites: 1))))
        XCTAssertEqual(try scratchLeftovers(), [])
    }

    func testOneFailingEntryTakesTheWholeArenaWithIt() throws {
        // Several entries have already spilled successfully when a later
        // one fails: the shared arena goes, not just the failing entry's part.
        var urls: [URL] = []
        for i in 0..<6 { urls.append(try input("n\(i).bin", noise(200 << 10, seed: UInt64(20 + i)))) }
        XCTAssertThrowsError(try ParallelCompressor.compress(
            urls, deflate: Array(repeating: true, count: urls.count),
            scratchDirectory: workDir, limits: limits(open: failing(afterWrites: 3))))
        XCTAssertEqual(try scratchLeftovers(), [])
    }

    func testPackRemovesTheArenaOnSuccessFailureAndCancellation() throws {
        let dir = workDir.appendingPathComponent("src")
        for i in 0..<4 { _ = try input("src/t\(i).txt", symbols(100 << 10, seed: UInt64(30 + i))) }
        var options = Packer.Options()
        options.clean = true

        // Success: everything forced to spill, arena gone, archive intact.
        let ok = try Packer.pack(inputs: [dir], output: workDir.appendingPathComponent("ok.zip"),
                                 options: options, limits: limits(budget: 0), progress: nil, shouldCancel: nil)
        XCTAssertEqual(try scratchLeftovers(), [])
        let reader = try ZipReader(url: ok.outputURL)
        XCTAssertEqual(reader.entries.filter { !$0.isDirectory }.count, 4)
        for entry in reader.entries where !entry.isDirectory {
            let name = reader.name(of: entry)
            XCTAssertEqual(try reader.extractData(entry),
                           try Data(contentsOf: workDir.appendingPathComponent(name)), name)
        }

        // Cancellation during the write phase: the arena belongs to the
        // pack and goes with the .part file.
        var calls = 0
        XCTAssertThrowsError(try Packer.pack(
            inputs: [dir], output: workDir.appendingPathComponent("cancelled.zip"),
            options: options, limits: limits(budget: 0), progress: nil,
            shouldCancel: { calls += 1; return calls > 2 }))
        XCTAssertEqual(try scratchLeftovers(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("cancelled.zip").path))

        // Failure inside compression.
        XCTAssertThrowsError(try Packer.pack(
            inputs: [dir], output: workDir.appendingPathComponent("failed.zip"),
            options: options, limits: limits(budget: 0, open: failing(afterWrites: 1)),
            progress: nil, shouldCancel: nil))
        XCTAssertEqual(try scratchLeftovers(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path)
                           .filter { $0.hasSuffix(".part") }, [])
    }

    // MARK: - Class C: finished results share an aggregate budget

    func testRetainedCompressedOutputStaysWithinTheMemoryBudget() throws {
        // Eight results of ~32 KiB each, every one below the 64 KiB spill
        // threshold; a budget of 100 KiB admits three of them.
        var urls: [URL] = []
        for i in 0..<8 { urls.append(try input("n\(i).bin", noise(32 << 10, seed: UInt64(40 + i)))) }
        let output = try ParallelCompressor.compress(
            urls, deflate: Array(repeating: true, count: urls.count),
            scratchDirectory: workDir, limits: limits(budget: 100 << 10))
        defer { output.cleanUp() }

        var retained = 0
        var inMemory = 0
        var spilled = 0
        for case .some(let result) in output.results {
            switch result.storage {
            case .memory(let data):
                retained += data.count
                inMemory += 1
            case .arena:
                spilled += 1
            }
            XCTAssertEqual(try inflate(result).count, 32 << 10)
        }
        XCTAssertEqual(inMemory + spilled, 8)
        XCTAssertLessThanOrEqual(retained, 100 << 10, "finished results must not exceed the budget")
        XCTAssertEqual(inMemory, 3, "three ~32 KiB results fit a 100 KiB budget")
        XCTAssertEqual(spilled, 5)
    }

    func testMemoryLedgerIsExactUnderConcurrentReservations() {
        // check-and-add must be one step: with a budget for 30 reservations
        // of 10, exactly 30 of 64 concurrent attempts succeed, never 31.
        for _ in 0..<20 {
            let ledger = MemoryLedger(budget: 300)
            let lock = NSLock()
            var granted = 0
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                if ledger.reserve(10) {
                    lock.lock()
                    granted += 1
                    lock.unlock()
                }
            }
            XCTAssertEqual(granted, 30)
            XCTAssertEqual(ledger.retained, 300)
        }
        let ledger = MemoryLedger(budget: 0)
        XCTAssertTrue(ledger.reserve(0), "an empty result always fits")
        XCTAssertFalse(ledger.reserve(1))
    }

    func testWhereAResultWasHeldDoesNotChangeTheArchive() throws {
        // Determinism (ADR-0002) must not depend on the budget: the same
        // input packed with everything in memory and with everything
        // spilled is the same file, byte for byte.
        let dir = workDir.appendingPathComponent("src")
        for i in 0..<6 { _ = try input("src/t\(i).txt", symbols(96 << 10, seed: UInt64(50 + i))) }
        let inMemory = try Packer.pack(inputs: [dir], output: workDir.appendingPathComponent("m.zip"),
                                       options: Packer.Options(), limits: limits(budget: .max),
                                       progress: nil, shouldCancel: nil)
        let spilled = try Packer.pack(inputs: [dir], output: workDir.appendingPathComponent("s.zip"),
                                      options: Packer.Options(), limits: limits(budget: 0),
                                      progress: nil, shouldCancel: nil)
        XCTAssertEqual(try Data(contentsOf: inMemory.outputURL), try Data(contentsOf: spilled.outputURL))
        XCTAssertEqual(try scratchLeftovers(), [])
    }

    func testForcedSpillsRoundTripThroughEncryption() throws {
        // Spilled results reach the encryptor in 256 KiB chunks, in-memory
        // ones in a single chunk; both ciphers must produce archives that
        // decrypt to the input.
        let dir = workDir.appendingPathComponent("src")
        let payloads = try (0..<3).map { i in
            let data = symbols(300 << 10, seed: UInt64(60 + i))
            _ = try input("src/e\(i).txt", data)
            return data
        }
        let ciphers: [(ZipWriter.Encryption, String)] = [
            (.aes256(password: "pw-1"), "pw-1"),
            (.zipCrypto(password: "pw-2"), "pw-2"),
        ]
        for (encryption, password) in ciphers {
            var options = Packer.Options()
            options.encryption = encryption
            let result = try Packer.pack(inputs: [dir], output: workDir.appendingPathComponent("enc.zip"),
                                         options: options, limits: limits(budget: 0),
                                         progress: nil, shouldCancel: nil)
            let reader = try ZipReader(url: result.outputURL)
            for (i, payload) in payloads.enumerated() {
                let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "src/e\(i).txt" })
                XCTAssertEqual(try reader.extractData(entry, password: password), payload)
            }
            try FileManager.default.removeItem(at: result.outputURL)
        }
        XCTAssertEqual(try scratchLeftovers(), [])
    }
}
