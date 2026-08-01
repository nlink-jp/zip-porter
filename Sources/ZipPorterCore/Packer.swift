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
    /// `progress` receives each archive path as work starts on it;
    /// `shouldCancel` is polled between entries — when it returns true the
    /// partial archive is removed and `CancellationError` is thrown.
    public static func pack(inputs: [URL],
                            output: URL,
                            options: Options = Options(),
                            progress: ((String) -> Void)? = nil,
                            shouldCancel: (() -> Bool)? = nil) throws -> Result {
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

        let actualOutput: URL
        if options.overwrite {
            try? fm.removeItem(at: output)
            actualOutput = output
        } else {
            actualOutput = PathUtil.uniqueURL(output)
        }
        var writerOptions = ZipWriter.Options()
        writerOptions.nameEncoding = options.nameEncoding
        writerOptions.encryption = options.encryption
        // Compress up front, in parallel, then write in order (ADR-013).
        // Entries that don't benefit from deflate are left to the writer's
        // streaming path, which stores them at I/O speed.
        let fileItems = items.enumerated().filter { !$0.element.isDirectory }
        let deflatable = fileItems.map { _, item in
            !ZipWriter.storeExtensions.contains((item.archivePath as NSString).pathExtension.lowercased())
                && ParallelCompressor.isWorthDeflating(item.url)
        }
        var compressed: [ParallelCompressor.Result?] = []
        if deflatable.contains(true) {
            compressed = try ParallelCompressor.compress(
                fileItems.map(\.element.url),
                deflate: deflatable,
                scratchDirectory: actualOutput.deletingLastPathComponent(),
                shouldCancel: shouldCancel)
        }
        defer { ParallelCompressor.cleanUp(compressed) }
        var precompressed: [Int: ParallelCompressor.Result] = [:]
        for (slot, (index, _)) in fileItems.enumerated() where slot < compressed.count {
            if let result = compressed[slot] { precompressed[index] = result }
        }

        let writer = try ZipWriter(url: actualOutput, options: writerOptions)
        var files = 0
        var directories = 0
        do {
            for (index, item) in items.enumerated() {
                if shouldCancel?() == true { throw CancellationError() }
                progress?(item.archivePath)
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
                    try writer.addFile(item.archivePath, fileURL: item.url,
                                       forceStore: true)
                    files += 1
                }
            }
            try writer.finalize()
        } catch {
            try? fm.removeItem(at: actualOutput)
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
