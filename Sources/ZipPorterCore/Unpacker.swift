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
        public var detectedEncoding: NameEncoding
    }

    public enum Failure: Error, Equatable {
        case emptyArchive
        case destinationNotADirectory(String)
    }

    /// Split a decoded entry name into safe path components, or nil when the
    /// path must be rejected (zip-slip). Backslashes count as separators —
    /// some Windows tools write them.
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

    /// `progress` receives each entry name as work starts on it;
    /// `shouldCancel` is polled between entries — on cancellation the
    /// half-written tree is removed and `CancellationError` is thrown.
    public static func unpack(zipURL: URL,
                              options: Options = Options(),
                              progress: ((String) -> Void)? = nil,
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
        var work: [(entry: ZipEntry, components: [String])] = []
        for entry in reader.entries {
            let name = reader.name(of: entry, forcedEncoding: options.forcedEncoding)
            guard let components = sanitize(name) else {
                skippedUnsafe.append(name)
                continue
            }
            if entry.isSymlink {
                skippedSymlinks.append(name)
                continue
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

        func extractAll() throws {
            for (entry, rawComponents) in work {
                if shouldCancel?() == true { throw CancellationError() }
                var components = rawComponents
                progress?(rawComponents.joined(separator: "/"))
                if let renamed = renames[components[0]] {
                    components[0] = renamed
                }
                let target = components.reduce(base) { $0.appendingPathComponent($1) }

                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    directories += 1
                } else {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: target.path, contents: nil)
                    let out = try FileHandle(forWritingTo: target)
                    do {
                        try reader.extract(entry, password: options.password) { chunk in
                            try out.write(contentsOf: chunk)
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
                    // Keep sane bits only, and never lock ourselves out.
                    let perms = (mode & 0o777) | (entry.isDirectory ? 0o700 : 0o600)
                    attrs[.posixPermissions] = NSNumber(value: perms)
                }
                if !attrs.isEmpty {
                    try? FileManager.default.setAttributes(attrs, ofItemAtPath: target.path)
                }
            }
        }

        do {
            try extractAll()
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
            detectedEncoding: options.forcedEncoding ?? reader.detectedEncoding)
    }
}
