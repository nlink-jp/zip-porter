import Darwin
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
                // Split into chunk-sized reads up front so the iterator
                // carries no cursor state.
                var chunks = ranges.flatMap { range in
                    stride(from: range.lowerBound, to: range.upperBound, by: chunkSize).map {
                        $0..<min($0 + UInt64(chunkSize), range.upperBound)
                    }
                }[...]
                return {
                    guard let next = chunks.popFirst() else { return nil }
                    return try arena.read(at: next.lowerBound,
                                          count: Int(next.upperBound - next.lowerBound))
                }
            }
        }
    }

    /// The knobs one `compress` call runs under, passed per call: production
    /// uses the defaults, tests pass small values and a failing scratch
    /// opener instead of mutating process-wide state (ADR-0005).
    struct Limits {
        /// Compressed output above this size goes to the arena while the
        /// entry is being compressed, so what any one worker holds is bounded.
        var spillThreshold = 16 << 20
        /// Aggregate ceiling on finished results kept in memory; nil means
        /// `cores × spillThreshold`, the bound ADR-0002 states. The per-entry
        /// threshold bounds the workers; this bounds what they hand back, so
        /// a folder of ten thousand small files does not accumulate its whole
        /// compressed size in RAM before the write phase starts.
        var memoryBudget: Int?
        /// Files at least this large compress as independent blocks in
        /// bounded waves (ADR-0003).
        var blockParallelThreshold: UInt64 = 32 << 20
        /// Opens the arena file: an exclusive create under a random hidden
        /// name. Injectable because no real filesystem fails a write on cue.
        var openScratch: (URL) throws -> ScratchFile = { try PathUtil.createExclusively(at: $0) }

        var resolvedMemoryBudget: Int {
            memoryBudget ?? max(ProcessInfo.processInfo.activeProcessorCount, 1) * spillThreshold
        }
    }

    static let chunkSize = 256 << 10
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
    /// anything skipped by cancellation). Throws the first failure seen.
    /// Spilled results live in `arena`, which the caller owns: it created
    /// it and removes it on every exit path. Nothing here owns anything on
    /// disk (ADR-0005).
    static func compress(_ urls: [URL],
                         deflate: [Bool],
                         arena: ScratchArena,
                         limits: Limits = Limits(),
                         onBytes: ((UInt64) -> Void)? = nil,
                         shouldCancel: (() -> Bool)? = nil) throws -> [Result?] {
        precondition(urls.count == deflate.count)
        var results = [Result?](repeating: nil, count: urls.count)
        guard !urls.isEmpty else { return results }

        // Large files get the block-parallel path one at a time; the rest
        // run whole-file, one per core (ADR-0002/0003).
        var smallIndexes: [Int] = []
        var largeIndexes: [Int] = []
        for (index, url) in urls.enumerated() where deflate[index] {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber)?.uint64Value ?? 0
            if size >= limits.blockParallelThreshold {
                largeIndexes.append(index)
            } else {
                smallIndexes.append(index)
            }
        }

        // concurrentPerform sizes itself to the machine's cores, so the
        // in-flight buffers are bounded by cores × spillThreshold; the ledger
        // bounds what the finished results retain (ADR-0005).
        let ledger = MemoryLedger(budget: limits.resolvedMemoryBudget)
        func sink() -> SpillSink {
            SpillSink(arena: arena, spillThreshold: limits.spillThreshold, ledger: ledger)
        }
        let lock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: smallIndexes.count) { slot in
            let index = smallIndexes[slot]
            lock.lock()
            let alreadyFailed = failure != nil
            lock.unlock()
            if alreadyFailed || shouldCancel?() == true { return }

            do {
                let result = try compressOne(urls[index], sink: sink(), onBytes: onBytes)
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
            results[index] = try compressLarge(urls[index], sink: sink(),
                                               onBytes: onBytes, shouldCancel: shouldCancel)
        }
        return results
    }

    /// Block-parallel compression of one large file (ADR-0003): read up to
    /// `cores` blocks, compress them concurrently, append in order, repeat.
    /// Every data block ends with a sync flush; a trailing empty Z_FINISH
    /// block closes the stream, so no EOF lookahead is needed. Peak memory
    /// is about cores × 2 × blockSize regardless of file size.
    private static func compressLarge(_ url: URL,
                                      sink: SpillSink,
                                      onBytes: ((UInt64) -> Void)?,
                                      shouldCancel: (() -> Bool)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var sink = sink
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
                                    sink: SpillSink,
                                    onBytes: ((UInt64) -> Void)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var sink = sink
        let deflater = try ZlibDeflateStream()
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0

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
    /// each. Once `ranges` is non-empty the entry has committed to the
    /// arena. The sink owns nothing on disk — the arena's owner does — so a
    /// failure anywhere in the entry needs no bookkeeping here (ADR-0005).
    private struct SpillSink {
        let arena: ScratchArena
        let spillThreshold: Int
        let ledger: MemoryLedger
        private var buffer = Data()
        private var ranges: [Range<UInt64>] = []

        init(arena: ScratchArena, spillThreshold: Int, ledger: MemoryLedger) {
            self.arena = arena
            self.spillThreshold = spillThreshold
            self.ledger = ledger
        }

        mutating func emit(_ chunk: Data) throws {
            buffer.append(chunk)
            if ranges.isEmpty {
                if buffer.count > spillThreshold { try flush() }
            } else if buffer.count >= ParallelCompressor.chunkSize {
                try flush()
            }
        }

        private mutating func flush() throws {
            guard !buffer.isEmpty else { return }
            let first = ranges.isEmpty
            ranges.append(try arena.append(buffer))
            if first {
                // Drop the ≥ threshold backing store; staging from here on
                // needs a chunk's worth.
                buffer = Data()
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        /// Hand the compressed bytes over. A result small enough to stay in
        /// memory still spills when the aggregate budget is spent.
        mutating func finish() throws -> Result.Storage {
            if ranges.isEmpty, ledger.reserve(buffer.count) {
                return .memory(buffer)
            }
            try flush()
            return .arena(arena, ranges)
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

/// The single scratch file behind one pack (ADR-0005): created on the first
/// spill — exclusively, under a hidden random name beside the archive —
/// owned by whoever constructed it (the `Packer`, whose one `defer` removes
/// it on every exit path), appended to by the compression workers under a
/// lock, and read back by the writer through one descriptor. One file with
/// one lifecycle, whatever the input count: no per-entry scratch files to
/// track on every failure branch, and nothing to litter the user's folder
/// with when the memory budget sends thousands of small results to disk.
final class ScratchArena {
    /// The arena is hidden while it lives; tests filter leftovers on this.
    static let namePrefix = ".zp-scratch-"

    let url: URL
    private let openScratch: (URL) throws -> ScratchFile
    private let lock = NSLock()
    private var writer: ScratchFile?
    private var reader: FileHandle?
    private var created = false
    private var removed = false
    private var end: UInt64 = 0

    init(directory: URL, openScratch: @escaping (URL) throws -> ScratchFile) {
        url = directory.appendingPathComponent(Self.namePrefix + UUID().uuidString)
        self.openScratch = openScratch
    }

    /// Append `data`, returning where it landed. Creates the file on first
    /// use; the handle is recorded under the lock in the same step, so there
    /// is no moment at which the file exists unowned.
    func append(_ data: Data) throws -> Range<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        precondition(!removed, "append to a removed arena")
        let handle: ScratchFile
        if let open = writer {
            handle = open
        } else {
            do {
                handle = try openScratch(url)
            } catch {
                // The user reads this; the arena's random name would tell
                // them nothing.
                throw ZipWriterError.ioError(
                    "cannot create a scratch file beside the archive: \(PathUtil.reason(of: error))")
            }
            writer = handle
            created = true
        }
        try handle.write(contentsOf: data)
        let range = end..<(end + UInt64(data.count))
        end = range.upperBound
        return range
    }

    /// Positioned read for the write phase, through one descriptor opened on
    /// first use — the write phase is sequential, and one open per pack beats
    /// one per spilled entry (thousands, once the budget is spent).
    func read(at offset: UInt64, count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        precondition(!removed, "read from a removed arena")
        guard count > 0 else { return Data() }
        let handle: FileHandle
        if let open = reader {
            handle = open
        } else {
            handle = try FileHandle(forReadingFrom: url)
            reader = handle
        }
        var data = Data(count: count)
        var done = 0
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            while done < count {
                let got = pread(handle.fileDescriptor, raw.baseAddress! + done,
                                count - done, off_t(offset) + off_t(done))
                guard got > 0 else {
                    throw ZipWriterError.ioError("scratch arena truncated at \(offset + UInt64(done))")
                }
                done += Int(got)
            }
        }
        return data
    }

    /// Close and delete the file if it was ever created. Idempotent.
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? writer?.close()
        writer = nil
        try? reader?.close()
        reader = nil
        if created {
            try? FileManager.default.removeItem(at: url)
        }
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
