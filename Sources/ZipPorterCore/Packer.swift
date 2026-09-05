import Foundation

/// Archive creation with the RFP's pack rules: junk filtering, NFC names,
/// deterministic entry order, symlinks skipped, never overwriting an
/// existing archive (unique output name).
public enum Packer {
    public struct Options: Sendable {
        public var nameEncoding: ZipWriter.NameEncoding = .utf8
        public var encryption: ZipWriter.Encryption = .none
        /// Apply the junk filter (`--no-clean` turns this off).
        public var clean = true
        /// Write to `output` exactly, replacing anything already there.
        /// Only for a path the user just chose in a save panel and
        /// confirmed replacing; otherwise a numbered name is used instead.
        public var overwrite = false
        public init() {}
    }

    public struct Result: Sendable {
        /// The archive actually written (uniquified if the requested name existed).
        public var outputURL: URL
        public var fileCount: Int
        public var directoryCount: Int
        public var skippedJunk: [String]
        public var skippedSymlinks: [String]
    }

    public enum Failure: Error, Equatable {
        case inputNotFound(String)
        case nothingToPack
    }

    /// Pack `inputs` (files and/or directories, all placed at the archive
    /// root) into `output` — or the uniquified variant of it.
    ///
    /// `progress` carries the current path and byte counts, so a UI can
    /// draw a real bar; `shouldCancel` is polled between entries — when it
    /// returns true the partial archive is removed and `CancellationError`
    /// is thrown. The archive is written under a temporary ".part" name and
    /// only renamed to the final one on success.
    public static func pack(inputs: [URL],
                            output: URL,
                            options: Options = Options(),
                            progress: ((OperationProgress) -> Void)? = nil,
                            shouldCancel: (() -> Bool)? = nil) throws -> Result {
        try pack(inputs: inputs, output: output, options: options, limits: .default,
                 progress: progress, shouldCancel: shouldCancel)
    }

    /// `limits` are the compressor's knobs (spill threshold, memory budget,
    /// scratch opener). Production runs on the defaults; tests pass small
    /// ones and a failing opener instead of mutating process-wide state.
    static func pack(inputs: [URL],
                     output: URL,
                     options: Options,
                     limits: ParallelCompressor.Limits,
                     progress: ((OperationProgress) -> Void)?,
                     shouldCancel: (() -> Bool)?) throws -> Result {
        // Collect (archivePath, fileURL?, isDirectory) first so entries are
        // sorted and junk/symlinks decided before any byte is written.
        struct Item {
            var archivePath: String
            var url: URL
            var isDirectory: Bool
        }
        let fm = FileManager.default
        let filter = JunkFilter()
        var items: [Item] = []
        var skippedJunk: [String] = []
        var skippedSymlinks: [String] = []

        func classify(_ url: URL, archivePath: String) throws -> Bool {
            // Returns false when the item was skipped.
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                skippedSymlinks.append(archivePath)
                return false
            }
            if options.clean && filter.isJunk(archivePath) {
                skippedJunk.append(archivePath)
                return false
            }
            items.append(Item(archivePath: archivePath, url: url,
                              isDirectory: values.isDirectory == true))
            return true
        }

        for input in inputs {
            let standardized = input.standardizedFileURL
            guard fm.fileExists(atPath: standardized.path) else {
                throw Failure.inputNotFound(standardized.path)
            }
            let top = standardized.lastPathComponent
            guard try classify(standardized, archivePath: top) else { continue }
            guard (try standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            // Path-based enumeration yields archive-relative paths directly —
            // URL-based enumeration standardizes /private/tmp → /tmp and
            // breaks prefix arithmetic. Note Foundation hides AppleDouble
            // ("._*") sidecars from every directory listing, so they can
            // never be packed, --no-clean or not.
            let enumerator = fm.enumerator(atPath: standardized.path)
            while let rel = enumerator?.nextObject() as? String {
                let archivePath = top + "/" + rel
                let type = enumerator?.fileAttributes?[.type] as? FileAttributeType
                if options.clean && filter.isJunk(archivePath) {
                    skippedJunk.append(archivePath)
                    // Junk directories (__MACOSX): don't descend either.
                    if type == .typeDirectory { enumerator?.skipDescendants() }
                    continue
                }
                if type == .typeSymbolicLink {
                    skippedSymlinks.append(archivePath)
                    continue
                }
                items.append(Item(archivePath: archivePath,
                                  url: standardized.appendingPathComponent(rel),
                                  isDirectory: type == .typeDirectory))
            }
        }
        guard !items.isEmpty else { throw Failure.nothingToPack }
        items.sort { $0.archivePath < $1.archivePath }

        let actualOutput = options.overwrite ? output : PathUtil.uniqueURL(output)
        // The archive materializes under a ".part" name so a half-written
        // file is never mistaken for a finished ZIP; the rename happens
        // after finalize() succeeds.
        let tempOutput = PathUtil.uniqueURL(actualOutput.appendingPathExtension("part"))

        // Byte-based progress: totals are known up front.
        var fileSizes: [Int: UInt64] = [:]
        for (index, item) in items.enumerated() where !item.isDirectory {
            fileSizes[index] = (try? fm.attributesOfItem(atPath: item.url.path)[.size]
                as? NSNumber)?.uint64Value ?? 0
        }
        let totalBytes = fileSizes.values.reduce(0, +)
        let progressLock = NSLock()
        var processedBytes: UInt64 = 0
        var currentPath = ""
        func report(_ path: String?, adding bytes: UInt64) {
            guard let progress else { return }
            progressLock.lock()
            defer { progressLock.unlock() }
            processedBytes &+= bytes
            if let path { currentPath = path }
            // Invoked under the lock so callers receive callbacks serially —
            // compression workers report from their own threads, and a
            // non-thread-safe observer (a test collecting into an array)
            // must not need its own synchronization.
            progress(OperationProgress(currentPath: currentPath,
                                       processedBytes: processedBytes,
                                       totalBytes: totalBytes))
        }
        var writerOptions = ZipWriter.Options()
        writerOptions.nameEncoding = options.nameEncoding
        writerOptions.encryption = options.encryption
        // Compress up front, in parallel, then write in order (ADR-0002).
        // Entries that don't benefit from deflate are left to the writer's
        // streaming path, which stores them at I/O speed.
        let fileItems = items.enumerated().filter { !$0.element.isDirectory }
        let deflatable = fileItems.map { _, item in
            !ZipWriter.storeExtensions.contains((item.archivePath as NSString).pathExtension.lowercased())
                && ParallelCompressor.isWorthDeflating(item.url)
        }
        var compressed: ParallelCompressor.Output?
        if deflatable.contains(true) {
            compressed = try ParallelCompressor.compress(
                fileItems.map(\.element.url),
                deflate: deflatable,
                scratchDirectory: actualOutput.deletingLastPathComponent(),
                limits: limits,
                onBytes: { report(nil, adding: $0) },
                shouldCancel: shouldCancel)
        }
        // The scratch arena the spilled results live in belongs to this
        // pack from here on; one release, whatever happens below.
        defer { compressed?.cleanUp() }
        var precompressed: [Int: ParallelCompressor.Result] = [:]
        if let results = compressed?.results {
            for (slot, (index, _)) in fileItems.enumerated() where slot < results.count {
                if let result = results[slot] { precompressed[index] = result }
            }
        }

        let writer = try ZipWriter(url: tempOutput, options: writerOptions)
        var files = 0
        var directories = 0
        do {
            for (index, item) in items.enumerated() {
                if shouldCancel?() == true { throw CancellationError() }
                report(item.archivePath, adding: 0)
                if item.isDirectory {
                    try writer.addDirectory(item.archivePath, modificationDate: modificationDate(of: item.url))
                    directories += 1
                } else if let ready = precompressed[index] {
                    try writer.addPrecompressed(
                        item.archivePath,
                        precompressed: ZipWriter.Precompressed(
                            method: .deflate,
                            crc32: ready.crc32,
                            uncompressedSize: ready.uncompressedSize),
                        modificationDate: modificationDate(of: item.url),
                        open: ready.open)
                    files += 1
                } else {
                    // Stored entries stream through the writer; their bytes
                    // were not counted by the compression phase.
                    try writer.addFile(item.archivePath, fileURL: item.url,
                                       forceStore: true,
                                       onBytes: { report(nil, adding: UInt64($0)) })
                    files += 1
                }
            }
            try writer.finalize()
            if options.overwrite {
                try? fm.removeItem(at: actualOutput)
            }
            try fm.moveItem(at: tempOutput, to: actualOutput)
        } catch {
            try? fm.removeItem(at: tempOutput)
            throw error
        }

        return Result(
            outputURL: actualOutput,
            fileCount: files,
            directoryCount: directories,
            skippedJunk: skippedJunk.sorted(),
            skippedSymlinks: skippedSymlinks.sorted())
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()
    }
}
