import Foundation

/// Compresses entries concurrently so packing uses every core, while the
/// writer still emits them in order (ADR-0002). Also decides, by measuring
/// rather than by file extension, which entries are not worth deflating.
enum ParallelCompressor {
    /// Compressed bytes for one entry: in memory when small, otherwise byte
    /// ranges in the pack's scratch arena.
    struct Result {
        var crc32: UInt32
        var uncompressedSize: UInt64
        var storage: Storage

        enum Storage {
            case memory(Data)
            /// Ranges in the arena, in emission order. Workers interleave
            /// their appends, so one entry's bytes are rarely contiguous.
            case arena(ScratchArena, [Range<UInt64>])
        }

        /// Fresh chunk iterator over the compressed bytes.
        func open() throws -> () throws -> Data? {
            switch storage {
            case .memory(let data):
                var sent = false
                return {
                    if sent || data.isEmpty { return nil }
                    sent = true
                    return data
                }
            case .arena(let arena, let ranges):
                let reader = try arena.openForReading()
                var pending = ranges[...]
                var consumed: UInt64 = 0
                return {
                    while let range = pending.first {
                        let from = range.lowerBound + consumed
                        if from >= range.upperBound {
                            pending.removeFirst()
                            consumed = 0
                            continue
                        }
                        let count = Int(min(UInt64(chunkSize), range.upperBound - from))
                        let chunk = try reader.read(at: from, count: count)
                        consumed += UInt64(chunk.count)
                        return chunk
                    }
                    try reader.close()
                    return nil
                }
            }
        }
    }

    /// What `compress` hands back: one result per input, and the arena the
    /// spilled ones reference. The caller owns the output from the return
    /// until `cleanUp()`; nothing else removes the arena (ADR-0005).
    struct Output {
        var results: [Result?]
        let arena: ScratchArena

        func cleanUp() {
            arena.remove()
        }
    }

    /// The knobs one `compress` call runs under. Production passes the
    /// defaults; tests pass small values and a failing scratch opener
    /// instead of mutating process-wide state.
    struct Limits {
        /// Compressed output above this size goes to the arena while the
        /// entry is being compressed, so what any one worker holds is bounded.
        var spillThreshold = 16 << 20
        /// Aggregate ceiling on finished results kept in memory (ADR-0005).
        /// The per-entry threshold bounds the workers; this bounds what they
        /// hand back, so a folder of ten thousand small files does not
        /// accumulate its whole compressed size in RAM before the write
        /// phase starts. `cores × spillThreshold` — the bound ADR-0002 states.
        var memoryBudget = max(ProcessInfo.processInfo.activeProcessorCount, 1) * (16 << 20)
        /// Opens the arena file: an exclusive create under a random hidden
        /// name. Injectable because no real filesystem fails a write on cue,
        /// and the arena's lifecycle cannot be tested otherwise.
        var openScratch: (URL) throws -> ScratchFile = { try PathUtil.createExclusively(at: $0) }

        static var `default`: Limits { Limits() }
    }

    static let chunkSize = 256 << 10
    /// Files at least this large compress as independent blocks in bounded
    /// waves (ADR-0003). Internal so tests can force the path with small data.
    static var blockParallelThreshold: UInt64 = 32 << 20
    /// Block granularity of the pigz-style join; ~16 MB costs no measurable
    /// ratio versus one stream.
    static let blockSize = 16 << 20
    /// How much of a file's head is test-compressed to decide whether
    /// deflating the whole thing is worth it.
    static let probeSize = 256 << 10
    /// Keep deflate only when the probe saves at least this fraction.
    /// Below it the entry is stored: faster, and smaller too, since deflate
    /// adds framing to data it cannot shrink.
    static let minimumSaving = 0.03

    /// True when deflating `url` looks worthwhile. Cheap files (below one
    /// probe) are answered by compressing them outright.
    static func isWorthDeflating(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: probeSize), !head.isEmpty else {
            return false
        }
        guard let produced = try? ZlibDeflate.compressBlock(head, isLast: true).count else {
            return true
        }
        return Double(produced) < Double(head.count) * (1 - minimumSaving)
    }

    /// Compress `urls` concurrently. Returns one result per input index, or
    /// nil for entries the caller should stream itself (stored entries, and
    /// anything skipped by cancellation). Throws the first failure seen —
    /// and removes the arena before doing so; on success the arena belongs
    /// to the returned `Output` until `cleanUp()`.
    static func compress(_ urls: [URL],
                         deflate: [Bool],
                         scratchDirectory: URL,
                         limits: Limits = .default,
                         onBytes: ((UInt64) -> Void)? = nil,
                         shouldCancel: (() -> Bool)? = nil) throws -> Output {
        precondition(urls.count == deflate.count)
        let arena = ScratchArena(directory: scratchDirectory, limits: limits)
        var results = [Result?](repeating: nil, count: urls.count)
        guard !urls.isEmpty else { return Output(results: results, arena: arena) }

        // Large files get the block-parallel path one at a time; the rest
        // run whole-file, one per core (ADR-0002/0003).
        var smallIndexes: [Int] = []
        var largeIndexes: [Int] = []
        for (index, url) in urls.enumerated() where deflate[index] {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.uint64Value ?? 0
            if size >= blockParallelThreshold {
                largeIndexes.append(index)
            } else {
                smallIndexes.append(index)
            }
        }

        // concurrentPerform sizes itself to the machine's cores, so the
        // in-flight buffers are bounded by cores × spillThreshold; the ledger
        // bounds what the finished results retain (ADR-0005).
        let ledger = MemoryLedger(budget: limits.memoryBudget)
        let lock = NSLock()
        var failure: Error?
        do {
            DispatchQueue.concurrentPerform(iterations: smallIndexes.count) { slot in
                let index = smallIndexes[slot]
                lock.lock()
                let alreadyFailed = failure != nil
                lock.unlock()
                if alreadyFailed || shouldCancel?() == true { return }

                do {
                    let result = try compressOne(urls[index], arena: arena, limits: limits,
                                                 ledger: ledger, onBytes: onBytes)
                    lock.lock()
                    results[index] = result
                    lock.unlock()
                } catch {
                    lock.lock()
                    if failure == nil { failure = error }
                    lock.unlock()
                }
            }
            if let failure { throw failure }

            for index in largeIndexes {
                if shouldCancel?() == true { break }
                results[index] = try compressLarge(urls[index], arena: arena, limits: limits,
                                                   ledger: ledger, onBytes: onBytes,
                                                   shouldCancel: shouldCancel)
            }
        } catch {
            // The one owner of the arena while compression runs.
            arena.remove()
            throw error
        }
        return Output(results: results, arena: arena)
    }

    /// Block-parallel compression of one large file (ADR-0003): read up to
    /// `cores` blocks, compress them concurrently, append in order, repeat.
    /// Every data block ends with a sync flush; a trailing empty Z_FINISH
    /// block closes the stream, so no EOF lookahead is needed. Peak memory
    /// is about cores × 2 × blockSize regardless of file size.
    private static func compressLarge(_ url: URL,
                                      arena: ScratchArena,
                                      limits: Limits,
                                      ledger: MemoryLedger,
                                      onBytes: ((UInt64) -> Void)?,
                                      shouldCancel: (() -> Bool)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var sink = SpillSink(arena: arena, limits: limits, ledger: ledger)
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)

        while true {
            if shouldCancel?() == true { throw CancellationError() }
            var wave: [Data] = []
            while wave.count < cores,
                  let chunk = try input.read(upToCount: blockSize), !chunk.isEmpty {
                crc = ZlibDeflate.crc32(crc, chunk)
                uncompressed += UInt64(chunk.count)
                onBytes?(UInt64(chunk.count))
                wave.append(chunk)
            }
            guard !wave.isEmpty else { break }

            let lock = NSLock()
            var outputs = [Data?](repeating: nil, count: wave.count)
            var failure: Error?
            DispatchQueue.concurrentPerform(iterations: wave.count) { i in
                do {
                    let out = try ZlibDeflate.compressBlock(wave[i], isLast: false)
                    lock.lock()
                    outputs[i] = out
                    lock.unlock()
                } catch {
                    lock.lock()
                    if failure == nil { failure = error }
                    lock.unlock()
                }
            }
            if let failure { throw failure }
            for output in outputs {
                try sink.emit(output ?? Data())
            }
            if wave.count < cores { break } // EOF reached inside this wave
        }
        try sink.emit(try ZlibDeflate.compressBlock(Data(), isLast: true))
        return Result(crc32: crc, uncompressedSize: uncompressed,
                      storage: try sink.finish())
    }

    private static func compressOne(_ url: URL,
                                    arena: ScratchArena,
                                    limits: Limits,
                                    ledger: MemoryLedger,
                                    onBytes: ((UInt64) -> Void)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let deflater = try ZlibDeflateStream()
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        var sink = SpillSink(arena: arena, limits: limits, ledger: ledger)

        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            crc = ZlibDeflate.crc32(crc, chunk)
            uncompressed += UInt64(chunk.count)
            onBytes?(UInt64(chunk.count))
            try deflater.process(chunk, final: false) { try sink.emit($0) }
        }
        try deflater.process(Data(), final: true) { try sink.emit($0) }
        return Result(crc32: crc, uncompressedSize: uncompressed,
                      storage: try sink.finish())
    }

    /// Where one entry's compressed bytes go while it is being compressed:
    /// memory up to the spill threshold, then the shared arena, staged in
    /// `chunkSize` pieces so small deflate outputs do not become one append
    /// each. The sink owns nothing on disk — the arena does — so a failure
    /// anywhere in the entry needs no bookkeeping here (ADR-0005).
    private struct SpillSink {
        let arena: ScratchArena
        let limits: Limits
        let ledger: MemoryLedger
        private var buffer = Data()
        private var ranges: [Range<UInt64>] = []
        private var spilled = false

        init(arena: ScratchArena, limits: Limits, ledger: MemoryLedger) {
            self.arena = arena
            self.limits = limits
            self.ledger = ledger
        }

        mutating func emit(_ chunk: Data) throws {
            buffer.append(chunk)
            if spilled {
                if buffer.count >= ParallelCompressor.chunkSize { try flush() }
            } else if buffer.count > limits.spillThreshold {
                spilled = true
                try flush()
            }
        }

        private mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            ranges.append(try arena.append(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        /// Hand the compressed bytes over. A result small enough to stay in
        /// memory still spills when the aggregate budget is spent.
        mutating func finish() throws -> Result.Storage {
            if !spilled, !ledger.reserve(buffer.count) {
                spilled = true
            }
            if spilled {
                try flush()
                return .arena(arena, ranges)
            }
            return .memory(buffer)
        }
    }
}

/// The open scratch file behind an arena. A protocol so tests can make
/// writes fail on cue, which no real filesystem does.
protocol ScratchFile: AnyObject {
    func write(contentsOf data: Data) throws
    func close() throws
}

extension FileHandle: ScratchFile {}

/// The single scratch file behind one `compress` call (ADR-0005): created
/// on the first spill — exclusively, under a hidden random name beside the
/// archive — owned by the call, and removed by `cleanUp` on every exit
/// path. Workers append under a lock and receive byte ranges back. One
/// file with one lifecycle, whatever the input count: no per-entry scratch
/// files to track on every failure branch, and nothing to litter the
/// user's folder with when the memory budget sends thousands of small
/// results to disk.
final class ScratchArena {
    let url: URL
    private let limits: ParallelCompressor.Limits
    private let lock = NSLock()
    private var file: ScratchFile?
    private var end: UInt64 = 0
    private var removed = false

    init(directory: URL, limits: ParallelCompressor.Limits) {
        url = directory.appendingPathComponent(".zp-scratch-\(UUID().uuidString)")
        self.limits = limits
    }

    /// Append `data`, returning where it landed. Creates the file on first
    /// use; the handle is recorded under the lock in the same step, so
    /// there is no moment at which the file exists unowned.
    func append(_ data: Data) throws -> Range<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        precondition(!removed, "append to a removed arena")
        let handle: ScratchFile
        if let open = file {
            handle = open
        } else {
            handle = try limits.openScratch(url)
            file = handle
        }
        try handle.write(contentsOf: data)
        let range = end..<(end + UInt64(data.count))
        end = range.upperBound
        return range
    }

    /// Bytes written so far (the arena file's size).
    var length: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return end
    }

    /// True once at least one result has spilled into the file.
    var exists: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    func openForReading() throws -> ArenaReader {
        try ArenaReader(url: url)
    }

    /// Close and delete the file if it was ever created. Idempotent.
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        guard let open = file else { return }
        try? open.close()
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Read side of the arena, one per `open()` of a result.
final class ArenaReader {
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipWriterError.ioError("scratch arena truncated")
        }
        return data
    }

    func close() throws {
        try handle.close()
    }
}

/// Aggregate budget for compressed results retained in memory across one
/// `compress` call (ADR-0005). Reservations are never returned: every
/// result lives until the write phase drains it, so within one call the
/// total only grows and the question is simply "does this still fit".
final class MemoryLedger {
    private let lock = NSLock()
    private let budget: Int
    private var reserved = 0

    init(budget: Int) {
        self.budget = max(budget, 0)
    }

    /// Reserve `bytes` if they fit; false means the caller must spill.
    func reserve(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bytes <= budget - reserved else { return false }
        reserved += bytes
        return true
    }

    /// Bytes reserved so far — what the finished results hold in memory.
    var retained: Int {
        lock.lock()
        defer { lock.unlock() }
        return reserved
    }
}
