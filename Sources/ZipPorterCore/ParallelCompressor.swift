import Foundation

/// Compresses entries concurrently so packing uses every core, while the
/// writer still emits them in order (ADR-013). Also decides, by measuring
/// rather than by file extension, which entries are not worth deflating.
enum ParallelCompressor {
    /// Compressed bytes for one entry, held in memory when small and
    /// spilled to a scratch file when not.
    struct Result {
        var crc32: UInt32
        var uncompressedSize: UInt64
        var storage: Storage

        enum Storage {
            case memory(Data)
            case spill(URL)
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
            case .spill(let url):
                let handle = try FileHandle(forReadingFrom: url)
                return {
                    let chunk = try handle.read(upToCount: chunkSize)
                    if chunk == nil || chunk!.isEmpty {
                        try handle.close()
                        return nil
                    }
                    return chunk
                }
            }
        }
    }

    static let chunkSize = 256 << 10
    /// Files at least this large compress as independent blocks in bounded
    /// waves (ADR-014). Internal so tests can force the path with small data.
    static var blockParallelThreshold: UInt64 = 32 << 20
    /// Block granularity of the pigz-style join; ~16 MB costs no measurable
    /// ratio versus one stream.
    static let blockSize = 16 << 20
    /// Compressed output above this size goes to a scratch file, so peak
    /// memory stays near `concurrency × threshold` instead of archive-sized.
    static let spillThreshold = 16 << 20
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
    static func compress(_ urls: [URL],
                         deflate: [Bool],
                         scratchDirectory: URL,
                         onBytes: ((UInt64) -> Void)? = nil,
                         shouldCancel: (() -> Bool)? = nil) throws -> [Result?] {
        precondition(urls.count == deflate.count)
        var results = [Result?](repeating: nil, count: urls.count)
        guard !urls.isEmpty else { return results }

        // Large files get the block-parallel path one at a time; the rest
        // run whole-file, one per core (ADR-013/014).
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

        // concurrentPerform sizes itself to the machine's cores, so peak
        // memory is bounded by cores × spillThreshold.
        let lock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: smallIndexes.count) { slot in
            let index = smallIndexes[slot]
            lock.lock()
            let alreadyFailed = failure != nil
            lock.unlock()
            if alreadyFailed || shouldCancel?() == true { return }

            do {
                let result = try compressOne(urls[index],
                                             scratchDirectory: scratchDirectory,
                                             index: index,
                                             onBytes: onBytes)
                lock.lock()
                results[index] = result
                lock.unlock()
            } catch {
                lock.lock()
                if failure == nil { failure = error }
                lock.unlock()
            }
        }

        if failure == nil {
            for index in largeIndexes {
                if shouldCancel?() == true { break }
                do {
                    results[index] = try compressLarge(urls[index],
                                                       scratchDirectory: scratchDirectory,
                                                       index: index,
                                                       onBytes: onBytes,
                                                       shouldCancel: shouldCancel)
                } catch {
                    failure = error
                    break
                }
            }
        }

        if let failure {
            cleanUp(results)
            throw failure
        }
        return results
    }

    /// Remove any scratch files still referenced by `results`.
    static func cleanUp(_ results: [Result?]) {
        for case .some(let result) in results {
            if case .spill(let url) = result.storage {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Block-parallel compression of one large file (ADR-014): read up to
    /// `cores` blocks, compress them concurrently, append in order, repeat.
    /// Every data block ends with a sync flush; a trailing empty Z_FINISH
    /// block closes the stream, so no EOF lookahead is needed. Peak memory
    /// is about cores × 2 × blockSize regardless of file size.
    private static func compressLarge(_ url: URL,
                                      scratchDirectory: URL,
                                      index: Int,
                                      onBytes: ((UInt64) -> Void)?,
                                      shouldCancel: (() -> Bool)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var sink = SpillSink(scratchDirectory: scratchDirectory, index: index)
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)

        while true {
            if shouldCancel?() == true {
                sink.abandon()
                throw CancellationError()
            }
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
            if let failure {
                sink.abandon()
                throw failure
            }
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
                                    scratchDirectory: URL,
                                    index: Int,
                                    onBytes: ((UInt64) -> Void)?) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let deflater = try ZlibDeflateStream()
        var crc: UInt32 = 0
        var uncompressed: UInt64 = 0
        var sink = SpillSink(scratchDirectory: scratchDirectory, index: index)

        do {
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                crc = ZlibDeflate.crc32(crc, chunk)
                uncompressed += UInt64(chunk.count)
                onBytes?(UInt64(chunk.count))
                try deflater.process(chunk, final: false) { try sink.emit($0) }
            }
            try deflater.process(Data(), final: true) { try sink.emit($0) }
        } catch {
            sink.abandon()
            throw error
        }
        return Result(crc32: crc, uncompressedSize: uncompressed,
                      storage: try sink.finish())
    }

    /// Accumulates compressed output in memory and moves to a scratch file
    /// once it grows past the spill threshold.
    private struct SpillSink {
        let scratchDirectory: URL
        let index: Int
        private var buffer = Data()
        private var spillURL: URL?
        private var spillHandle: FileHandle?

        init(scratchDirectory: URL, index: Int) {
            self.scratchDirectory = scratchDirectory
            self.index = index
        }

        mutating func emit(_ chunk: Data) throws {
            if let spillHandle {
                try spillHandle.write(contentsOf: chunk)
                return
            }
            buffer.append(chunk)
            guard buffer.count > ParallelCompressor.spillThreshold else { return }
            let url = scratchDirectory.appendingPathComponent(
                "zp-\(index)-\(UUID().uuidString).deflate")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ZipWriterError.ioError("cannot create scratch file")
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: buffer)
            buffer = Data()
            spillURL = url
            spillHandle = handle
        }

        mutating func finish() throws -> Result.Storage {
            if let spillHandle, let spillURL {
                try spillHandle.close()
                self.spillHandle = nil
                return .spill(spillURL)
            }
            return .memory(buffer)
        }

        /// Failure path: close and delete any scratch file.
        mutating func abandon() {
            try? spillHandle?.close()
            spillHandle = nil
            if let spillURL {
                try? FileManager.default.removeItem(at: spillURL)
            }
            spillURL = nil
        }
    }
}
