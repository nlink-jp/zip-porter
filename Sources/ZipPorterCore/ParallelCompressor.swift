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
        guard let deflater = try? DeflateStream(.compress) else { return true }
        var produced = 0
        do {
            try deflater.process(head, final: true) { produced += $0.count }
        } catch {
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
                         progress: ((Int) -> Void)? = nil,
                         shouldCancel: (() -> Bool)? = nil) throws -> [Result?] {
        precondition(urls.count == deflate.count)
        var results = [Result?](repeating: nil, count: urls.count)
        guard !urls.isEmpty else { return results }

        // concurrentPerform sizes itself to the machine's cores, so peak
        // memory is bounded by cores × spillThreshold.
        let lock = NSLock()
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            guard deflate[index] else { return }
            lock.lock()
            let alreadyFailed = failure != nil
            lock.unlock()
            if alreadyFailed || shouldCancel?() == true { return }

            do {
                let result = try compressOne(urls[index],
                                             scratchDirectory: scratchDirectory,
                                             index: index)
                lock.lock()
                results[index] = result
                lock.unlock()
                progress?(index)
            } catch {
                lock.lock()
                if failure == nil { failure = error }
                lock.unlock()
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

    private static func compressOne(_ url: URL,
                                    scratchDirectory: URL,
                                    index: Int) throws -> Result {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let deflater = try DeflateStream(.compress)
        var crc = CRC32()
        var uncompressed: UInt64 = 0

        var buffer = Data()
        var spillURL: URL?
        var spillHandle: FileHandle?

        func emit(_ chunk: Data) throws {
            if let spillHandle {
                try spillHandle.write(contentsOf: chunk)
                return
            }
            buffer.append(chunk)
            guard buffer.count > spillThreshold else { return }
            // Grown past the memory budget: move what we have to a file and
            // keep streaming there.
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

        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            crc.update(chunk)
            uncompressed += UInt64(chunk.count)
            try deflater.process(chunk, final: false, sink: emit)
        }
        try deflater.process(Data(), final: true, sink: emit)

        if let spillHandle, let spillURL {
            try spillHandle.close()
            return Result(crc32: crc.value, uncompressedSize: uncompressed,
                          storage: .spill(spillURL))
        }
        return Result(crc32: crc.value, uncompressedSize: uncompressed,
                      storage: .memory(buffer))
    }
}
