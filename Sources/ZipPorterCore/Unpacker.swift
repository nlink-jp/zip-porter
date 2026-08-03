import Foundation

/// Extraction with the safety and UX rules from the RFP: zip-slip guard,
/// symlinks skipped, never overwrite existing files (unique names), and
/// multi-top-level archives wrapped in a folder named after the ZIP.
public enum Unpacker {
    /// When to wrap extracted content in a new folder named after the ZIP
    /// (The Unarchiver's "展開したファイル用の新規フォルダを作成").
    public enum FolderPolicy: Sendable, Equatable {
        /// Only when the archive has multiple top-level items (default).
        case onlyMultipleTopLevel
        case always
        case never
    }

    public struct Options: Sendable {
        /// Destination directory; default is the ZIP's own directory.
        public var destination: URL?
        public var password: String?
        /// Force the name encoding for entries without the UTF-8 flag.
        public var forcedEncoding: NameEncoding?
        public var folderPolicy: FolderPolicy = .onlyMultipleTopLevel
        public init() {}
    }

    public struct Result: Sendable {
        /// Where the content landed: the wrapper folder, the single
        /// top-level item, or the destination directory itself.
        public var root: URL
        /// The top-level items that were created (for Finder reveal).
        public var extractedTopItems: [URL]
        /// True when a wrapper folder was created by this extraction.
        public var createdWrapper: Bool
        public var extractedFiles: Int
        public var extractedDirectories: Int
        /// Entry names skipped because their paths escape the destination
        /// (absolute, "..", drive letters) — the zip-slip guard.
        public var skippedUnsafe: [String]
        /// Symlink entries skipped by policy.
        public var skippedSymlinks: [String]
        /// Entries whose names collided with an earlier entry and were
        /// extracted under a numbered name ("original" → "chosen").
        public var renamedDuplicates: [(original: String, chosen: String)]
        /// True when the archive carried a quarantine attribute and it was
        /// applied to every item extracted from it.
        public var quarantinePropagated: Bool
        /// Items the quarantine attribute could not be set on. Non-empty
        /// means part of what was extracted is invisible to Gatekeeper —
        /// a security-relevant outcome, so it is reported rather than
        /// swallowed (ADR-0001).
        public var quarantineFailures: [String]
        public var detectedEncoding: NameEncoding
    }

    public enum Failure: Error, Equatable {
        case emptyArchive
        case destinationNotADirectory(String)
        /// The archive declares more content than the destination volume
        /// can hold — checked before writing anything (ADR-0001 §2).
        case insufficientSpace(required: UInt64, available: UInt64)
    }

    /// Headroom left free on the destination volume by the pre-flight
    /// budget check.
    static let spaceMargin: UInt64 = 64 << 20

    /// Free bytes on the volume holding `url`, or nil when unavailable
    /// (the budget check then simply does not run).
    static func freeSpace(at url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity >= 0 ? UInt64(capacity) : nil
    }

    /// Split a decoded entry name into safe path components, or nil when the
    /// path must be rejected (zip-slip). Backslashes count as separators —
    /// some Windows tools write them.
    /// `sanitize` exposed for `inspect`, so a diagnostic run reports the
    /// same verdict extraction would reach.
    public static func sanitizeForDiagnostics(_ decodedName: String) -> [String]? {
        sanitize(decodedName)
    }

    static func sanitize(_ decodedName: String) -> [String]? {
        let unified = decodedName.replacingOccurrences(of: "\\", with: "/")
        if unified.hasPrefix("/") { return nil }
        var components: [String] = []
        for raw in unified.split(separator: "/") {
            let component = String(raw)
            if component == "." || component.isEmpty { continue }
            if component == ".." { return nil }
            // Windows drive prefixes and NTFS alternate data streams.
            if component.contains(":") { return nil }
            components.append(component)
        }
        return components.isEmpty ? nil : components
    }

    /// `progress` carries the current entry and byte counts (totals come
    /// from the central directory, so the fraction is exact);
    /// `shouldCancel` is polled between entries — on cancellation the
    /// half-written tree is removed and `CancellationError` is thrown.
    public static func unpack(zipURL: URL,
                              options: Options = Options(),
                              progress: ((OperationProgress) -> Void)? = nil,
                              shouldCancel: (() -> Bool)? = nil) throws -> Result {
        let reader = try ZipReader(url: zipURL)
        let destBase = options.destination ?? zipURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destBase.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw Failure.destinationNotADirectory(destBase.path)
            }
        } else {
            // `-o` behaves like unzip -d: create the destination if needed.
            try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
        }

        var skippedUnsafe: [String] = []
        var skippedSymlinks: [String] = []
        var renamedDuplicates: [(original: String, chosen: String)] = []
        var work: [(entry: ZipEntry, components: [String])] = []
        // Collision keys are NFC + case-folded because APFS is
        // case-insensitive by default and stores either normalization —
        // "Report.txt", "report.txt" and an NFD "データ.txt" all land on
        // one file if we don't uniquify (ADR-0001 §5).
        var claimedPaths = Set<String>()
        func collisionKey(_ components: [String]) -> String {
            components.joined(separator: "/")
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }

        for entry in reader.entries {
            let name = reader.name(of: entry, forcedEncoding: options.forcedEncoding)
            guard var components = sanitize(name) else {
                skippedUnsafe.append(name)
                continue
            }
            if entry.isSymlink {
                skippedSymlinks.append(name)
                continue
            }
            // Directories legitimately repeat (a parent listed once per
            // archive plus implied by children); only files collide.
            if !entry.isDirectory {
                let originalPath = components.joined(separator: "/")
                if claimedPaths.contains(collisionKey(components)) {
                    let leaf = components[components.count - 1]
                    var n = 2
                    repeat {
                        components[components.count - 1] = PathUtil.numberedVariant(leaf, n)
                        n += 1
                    } while claimedPaths.contains(collisionKey(components))
                    renamedDuplicates.append(
                        (original: originalPath, chosen: components[components.count - 1]))
                }
                claimedPaths.insert(collisionKey(components))
            }
            work.append((entry, components))
        }
        guard !work.isEmpty else { throw Failure.emptyArchive }

        // Fail before touching the disk: a retry after the password prompt
        // must not find debris from this attempt (and land in "name 2").
        if options.password == nil,
           work.contains(where: { $0.entry.encryption != .none && !$0.entry.isDirectory }) {
            throw ZipReaderError.passwordRequired
        }

        // Pre-flight budget: refuse before writing when the declared
        // content cannot fit on the destination volume. This is what stops
        // overlap bombs from filling a disk even when every individual
        // entry is honest about its own size (ADR-0001 §2).
        let required = reader.declaredTotalSize
        if let available = freeSpace(at: destBase) {
            // Phrased as a subtraction from the free space: `required +
            // margin` would wrap for a saturated total and turn the refusal
            // into an approval.
            let budget = available > Self.spaceMargin ? available - Self.spaceMargin : 0
            guard required <= budget else {
                throw Failure.insufficientSpace(required: required, available: available)
            }
        }

        // Folder policy decides whether content goes into a wrapper folder
        // named after the ZIP. Top-level names are always uniquified so
        // nothing existing is ever touched.
        let topNames = Set(work.map { $0.components[0] })
        let wrap: Bool
        switch options.folderPolicy {
        case .always: wrap = true
        case .never: wrap = false
        case .onlyMultipleTopLevel: wrap = topNames.count > 1
        }

        let root: URL
        let base: URL
        var renames: [String: String] = [:]
        var topItems: [URL] = []
        if wrap {
            let stem = zipURL.deletingPathExtension().lastPathComponent
            let wrapper = PathUtil.uniqueURL(
                destBase.appendingPathComponent(stem.isEmpty ? "Archive" : stem))
            try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
            root = wrapper
            base = wrapper
            topItems = [wrapper]
        } else {
            // Uniquify each top-level name — against the filesystem AND the
            // other assigned names, so "docs"→"docs 2" can't collide with a
            // genuine "docs 2" top-level entry.
            var assigned = Set<String>()
            for top in topNames.sorted() {
                let final = PathUtil.uniqueName(top) { candidate in
                    assigned.contains(candidate)
                        || FileManager.default.fileExists(
                            atPath: destBase.appendingPathComponent(candidate).path)
                }
                assigned.insert(final)
                if final != top { renames[top] = final }
                topItems.append(destBase.appendingPathComponent(final))
            }
            base = destBase
            root = topItems.count == 1 ? topItems[0] : destBase
        }

        var files = 0
        var directories = 0
        let totalBytes = reader.declaredTotalSize
        var processedBytes: UInt64 = 0
        // Downloaded archives carry com.apple.quarantine; everything we
        // write from them must carry it too, or Gatekeeper never sees the
        // contents (ADR-0001 §4).
        let quarantine = XattrUtil.quarantine(of: zipURL)
        var quarantineFailures: [String] = []
        /// Apply the attribute and remember the item if it would not take —
        /// a silent failure here is a Gatekeeper bypass nobody hears about.
        func applyQuarantine(to url: URL, named name: String) {
            guard let quarantine else { return }
            if !XattrUtil.applyQuarantine(quarantine, to: url) {
                quarantineFailures.append(name)
            }
        }
        if wrap {
            applyQuarantine(to: root, named: root.lastPathComponent)
        }

        // Every directory this extraction brings into existence, relative to
        // `base` — including the ones `withIntermediateDirectories` creates
        // on the way to a nested file. Quarantine has to reach these too:
        // an archive with no directory entries (7-Zip writes them that way
        // routinely, and an attacker would deliberately) otherwise yields a
        // `.app` whose files are each quarantined but whose bundle root —
        // the thing Gatekeeper evaluates — is not (ADR-0001 §4).
        var createdDirectories: Set<String> = []
        func recordDirectories(_ components: some Collection<String>) {
            var prefix: [String] = []
            for component in components {
                prefix.append(component)
                createdDirectories.insert(prefix.joined(separator: "/"))
            }
        }

        func extractAll() throws {
            for (entry, rawComponents) in work {
                if shouldCancel?() == true { throw CancellationError() }
                var components = rawComponents
                let entryPath = rawComponents.joined(separator: "/")
                progress?(OperationProgress(currentPath: entryPath,
                                            processedBytes: processedBytes,
                                            totalBytes: totalBytes))
                if let renamed = renames[components[0]] {
                    components[0] = renamed
                }
                let target = components.reduce(base) { $0.appendingPathComponent($1) }

                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    recordDirectories(components)
                    directories += 1
                } else {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    recordDirectories(components.dropLast())
                    let out = try PathUtil.createExclusively(at: target)
                    do {
                        try reader.extract(entry, password: options.password) { chunk in
                            try out.write(contentsOf: chunk)
                            processedBytes &+= UInt64(chunk.count)
                            progress?(OperationProgress(currentPath: entryPath,
                                                        processedBytes: processedBytes,
                                                        totalBytes: totalBytes))
                        }
                        try out.close()
                    } catch {
                        try? out.close()
                        try? FileManager.default.removeItem(at: target)
                        throw error
                    }
                    files += 1
                }

                var attrs: [FileAttributeKey: Any] = [:]
                if let mtime = DOSDateTime.toDate(date: entry.dosDate, time: entry.dosTime) {
                    attrs[.modificationDate] = mtime
                }
                if let mode = entry.unixMode {
                    // The archive asks; the umask decides. Owner bits are
                    // kept so we never lock ourselves out.
                    attrs[.posixPermissions] = NSNumber(
                        value: PosixPermissions.extracted(mode: mode,
                                                          isDirectory: entry.isDirectory))
                }
                if !attrs.isEmpty {
                    try? FileManager.default.setAttributes(attrs, ofItemAtPath: target.path)
                }
                applyQuarantine(to: target, named: entryPath)
            }
        }

        do {
            try extractAll()
            // Directories last: the attribute survives writes into them,
            // and doing it here covers implicit parents in one pass.
            for path in createdDirectories.sorted() {
                let url = path.split(separator: "/")
                    .reduce(base) { $0.appendingPathComponent(String($1)) }
                applyQuarantine(to: url, named: path)
            }
        } catch {
            // Never leave a half-written tree behind. Remove only the
            // top-level items this call created — `root` can be the
            // pre-existing destination directory under `.never`.
            for item in topItems {
                try? FileManager.default.removeItem(at: item)
            }
            throw error
        }

        return Result(
            root: root,
            extractedTopItems: topItems,
            createdWrapper: wrap,
            extractedFiles: files,
            extractedDirectories: directories,
            skippedUnsafe: skippedUnsafe,
            skippedSymlinks: skippedSymlinks,
            renamedDuplicates: renamedDuplicates,
            quarantinePropagated: quarantine != nil && quarantineFailures.isEmpty,
            quarantineFailures: quarantineFailures,
            detectedEncoding: options.forcedEncoding ?? reader.detectedEncoding)
    }
}
