import XCTest
@testable import ZipPorterCore

/// ADR-0005 for the parallel compressor: class A (one scratch arena per pack,
/// owned by the pack from creation to removal, whatever fails) and class C
/// (finished results share an aggregate memory budget). Write failures are
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
                        budget: Int? = .max,
                        open: ((URL) throws -> ScratchFile)? = nil) -> ParallelCompressor.Limits {
        var limits = ParallelCompressor.Limits()
        limits.spillThreshold = spill
        limits.memoryBudget = budget
        if let open { limits.openScratch = open }
        return limits
    }

    private func arena(_ limits: ParallelCompressor.Limits) -> ScratchArena {
        ScratchArena(directory: workDir, openScratch: limits.openScratch)
    }

    private func input(_ name: String, _ data: Data) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func leftovers() throws -> [String] {
        try TestSupport.scratchLeftovers(in: workDir)
    }

    private func inflate(_ result: ParallelCompressor.Result) throws -> Data {
        var compressed = Data()
        let next = try result.open()
        while let chunk = try next() { compressed.append(chunk) }
        var out = Data()
        try DeflateStream(.decompress).process(compressed, final: true) { out.append($0) }
        return out
    }

    /// Pack `dir` through the internal overload that takes limits.
    private func pack(_ dir: URL, to name: String, limits: ParallelCompressor.Limits,
                      options: Packer.Options = Packer.Options(),
                      shouldCancel: (() -> Bool)? = nil) throws -> Packer.Result {
        try Packer.pack(inputs: [dir], output: workDir.appendingPathComponent(name),
                        options: options, limits: limits, progress: nil, shouldCancel: shouldCancel)
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

    /// Compressible inputs above the 64 KiB spill threshold once deflated.
    private func spillingCorpus(_ count: Int, in dir: String = "src") throws -> URL {
        for i in 0..<count {
            _ = try input("\(dir)/t\(i).txt", TestSupport.symbols(300 << 10, seed: UInt64(100 + i)))
        }
        return workDir.appendingPathComponent(dir)
    }

    // MARK: - Class A: one arena, owned by the pack from creation to removal

    func testArenaIsCreatedOnFirstSpillHiddenAndRemovedByItsOwner() throws {
        let quiet = arena(limits())
        let small = try input("s.bin", TestSupport.noise(1000, seed: 1))
        _ = try ParallelCompressor.compress([small], deflate: [true], arena: quiet, limits: limits())
        XCTAssertEqual(try leftovers(), [], "nothing spilled, nothing created")
        quiet.remove()

        let busy = arena(limits())
        let big = try input("b.bin", TestSupport.noise(256 << 10, seed: 2))
        let results = try ParallelCompressor.compress([big], deflate: [true], arena: busy, limits: limits())
        let names = try leftovers()
        XCTAssertEqual(names.count, 1, "one arena per pack: \(names)")
        XCTAssertTrue(names[0].hasPrefix("."), "hidden from Finder while it lives")
        XCTAssertEqual(try inflate(try XCTUnwrap(results[0])), TestSupport.noise(256 << 10, seed: 2))
        busy.remove()
        XCTAssertEqual(try leftovers(), [])
        busy.remove() // idempotent
    }

    func testArenaCreationFailureIsReportedWithoutTheArenasName() throws {
        // The user reads this message: a read-only destination must say so,
        // not print a random hidden filename.
        let denied = limits(open: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) })
        let dir = try spillingCorpus(1)
        XCTAssertThrowsError(try pack(dir, to: "out.zip", limits: denied)) { error in
            guard case .ioError(let message) = error as? ZipWriterError else {
                return XCTFail("expected ZipWriterError.ioError, got \(error)")
            }
            XCTAssertTrue(message.contains("Permission denied"), message)
            XCTAssertFalse(message.contains("zp-scratch"), "internal file name leaked: \(message)")
        }
        XCTAssertEqual(try leftovers(), [])
    }

    func testPackRemovesTheArenaWhenItsFirstWriteFails() throws {
        // The write that fails is the one that would have made the file
        // known under the old per-entry design.
        let dir = try spillingCorpus(1)
        XCTAssertThrowsError(try pack(dir, to: "out.zip", limits: limits(open: failing(afterWrites: 0))))
        XCTAssertEqual(try leftovers(), [], "a half-written arena must not survive the failure")
    }

    func testPackRemovesTheArenaWhenALaterWriteFails() throws {
        let dir = try spillingCorpus(1)
        _ = try input("src/big.txt", TestSupport.symbols(2 << 20, seed: 7))
        XCTAssertThrowsError(try pack(dir, to: "out.zip", limits: limits(open: failing(afterWrites: 2))))
        XCTAssertEqual(try leftovers(), [])
    }

    func testPackRemovesTheArenaEvenWhenItsCloseFails() throws {
        let dir = try spillingCorpus(1)
        _ = try pack(dir, to: "out.zip", limits: limits(open: failing(afterWrites: .max, failClose: true)))
        XCTAssertEqual(try leftovers(), [], "a failing close must not keep the file alive")
    }

    func testPackRemovesTheArenaWhenBlockParallelCompressionFailsToWrite() throws {
        var limits = limits(open: failing(afterWrites: 1))
        limits.blockParallelThreshold = 1 << 10
        _ = try input("src/big.bin", TestSupport.symbols(600 << 10, seed: 6))
        XCTAssertThrowsError(try pack(workDir.appendingPathComponent("src"), to: "out.zip", limits: limits))
        XCTAssertEqual(try leftovers(), [])
    }

    func testOneFailingEntryTakesTheWholeArenaWithIt() throws {
        // Several entries have already spilled successfully when a later
        // one fails: the shared arena goes, not just the failing entry's part.
        let dir = try spillingCorpus(6)
        XCTAssertThrowsError(try pack(dir, to: "out.zip", limits: limits(open: failing(afterWrites: 3))))
        XCTAssertEqual(try leftovers(), [])
    }

    func testPackRemovesTheArenaOnSuccessAndCancellation() throws {
        let dir = try spillingCorpus(4)

        // Success: everything forced to spill, arena gone, archive intact.
        let ok = try pack(dir, to: "ok.zip", limits: limits(budget: 0))
        XCTAssertEqual(try leftovers(), [])
        let reader = try ZipReader(url: ok.outputURL)
        XCTAssertEqual(reader.entries.filter { !$0.isDirectory }.count, 4)
        for entry in reader.entries where !entry.isDirectory {
            let name = reader.name(of: entry)
            XCTAssertEqual(try reader.extractData(entry),
                           try Data(contentsOf: workDir.appendingPathComponent(name)), name)
        }

        // Cancellation during the write phase: the arena belongs to the
        // pack and goes with the .part file.
        let cancel = TestSupport.CancelAfter(2)
        XCTAssertThrowsError(try pack(dir, to: "cancelled.zip", limits: limits(budget: 0),
                                      shouldCancel: cancel.poll))
        XCTAssertEqual(try leftovers(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("cancelled.zip").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path)
                           .filter { $0.hasSuffix(".part") }, [])
    }

    // MARK: - Class C: finished results share an aggregate budget

    func testRetainedCompressedOutputStaysWithinTheMemoryBudget() throws {
        // Eight results of ~32 KiB each, every one below the 64 KiB spill
        // threshold; a budget of 100 KiB admits three of them.
        let limits = limits(budget: 100 << 10)
        let shared = arena(limits)
        defer { shared.remove() }
        var urls: [URL] = []
        for i in 0..<8 { urls.append(try input("n\(i).bin", TestSupport.noise(32 << 10, seed: UInt64(40 + i)))) }
        let results = try ParallelCompressor.compress(
            urls, deflate: Array(repeating: true, count: urls.count), arena: shared, limits: limits)

        var retained = 0
        var inMemory = 0
        var spilled = 0
        for case .some(let result) in results {
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

    func testMemoryBudgetDefaultsToCoresTimesSpillThreshold() {
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        XCTAssertEqual(ParallelCompressor.Limits().resolvedMemoryBudget, cores * (16 << 20))
        var small = ParallelCompressor.Limits()
        small.spillThreshold = 1000
        XCTAssertEqual(small.resolvedMemoryBudget, cores * 1000, "the budget follows the threshold")
        small.memoryBudget = 5
        XCTAssertEqual(small.resolvedMemoryBudget, 5)
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
        for i in 0..<6 { _ = try input("src/t\(i).txt", TestSupport.symbols(96 << 10, seed: UInt64(50 + i))) }
        let dir = workDir.appendingPathComponent("src")
        let inMemory = try pack(dir, to: "m.zip", limits: limits(budget: .max))
        let spilled = try pack(dir, to: "s.zip", limits: limits(budget: 0))
        XCTAssertEqual(try Data(contentsOf: inMemory.outputURL), try Data(contentsOf: spilled.outputURL))
        XCTAssertEqual(try leftovers(), [])
    }

    func testForcedSpillsRoundTripThroughEncryption() throws {
        // Spilled results reach the encryptor in 256 KiB chunks, in-memory
        // ones in a single chunk; both ciphers must produce archives that
        // decrypt to the input.
        let dir = try spillingCorpus(3)
        let payloads = try (0..<3).map { try Data(contentsOf: dir.appendingPathComponent("t\($0).txt")) }
        let ciphers: [(ZipWriter.Encryption, String)] = [
            (.aes256(password: "pw-1"), "pw-1"),
            (.zipCrypto(password: "pw-2"), "pw-2"),
        ]
        for (encryption, password) in ciphers {
            var options = Packer.Options()
            options.encryption = encryption
            let result = try pack(dir, to: "enc.zip", limits: limits(budget: 0), options: options)
            let reader = try ZipReader(url: result.outputURL)
            for (i, payload) in payloads.enumerated() {
                let entry = try XCTUnwrap(reader.entries.first { reader.name(of: $0) == "src/t\(i).txt" })
                XCTAssertEqual(try reader.extractData(entry, password: password), payload)
            }
            try FileManager.default.removeItem(at: result.outputURL)
        }
        XCTAssertEqual(try leftovers(), [])
    }
}
