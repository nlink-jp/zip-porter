import Foundation

/// Extraction with the safety and UX rules from the RFP: zip-slip guard,
/// symlinks skipped, never overwrite existing files (unique names), and
/// multi-top-level archives wrapped in a folder named after the ZIP.
public enum Unpacker {
    public struct Options: Sendable {
        /// Destination directory; default is the ZIP's own directory.
        public var destination: URL?
        public var password: String?
        /// Force the name encoding for entries without the UTF-8 flag.
        public var forcedEncoding: NameEncoding?
        public init() {}
    }

    public struct Result: Sendable {
        /// Where the content landed: the wrapper folder, the single
        /// top-level item, or the destination directory itself.
        public var root: URL
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

    public static func unpack(zipURL: URL, options: Options = Options()) throws -> Result {
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

        // Single top-level item extracts as itself; anything else is wrapped
        // in a folder named after the archive. Either way the top-level name
        // is uniquified so nothing existing is ever touched.
        let topNames = Set(work.map { $0.components[0] })
        let root: URL
        var rename: (from: String, to: String)?
        if topNames.count == 1, let top = topNames.first {
            let target = PathUtil.uniqueURL(destBase.appendingPathComponent(top))
            root = target
            if target.lastPathComponent != top {
                rename = (top, target.lastPathComponent)
            }
        } else {
            let stem = zipURL.deletingPathExtension().lastPathComponent
            let wrapper = PathUtil.uniqueURL(
                destBase.appendingPathComponent(stem.isEmpty ? "Archive" : stem))
            try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
            root = wrapper
            rename = nil
        }

        var files = 0
        var directories = 0
        let base = topNames.count == 1 ? destBase : root

        func extractAll() throws {
            for (entry, rawComponents) in work {
                var components = rawComponents
                if let rename, components[0] == rename.from {
                    components[0] = rename.to
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
            // Never leave a half-written tree behind; `root` is always a
            // path this call created.
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        return Result(
            root: root,
            extractedFiles: files,
            extractedDirectories: directories,
            skippedUnsafe: skippedUnsafe,
            skippedSymlinks: skippedSymlinks,
            detectedEncoding: options.forcedEncoding ?? reader.detectedEncoding)
    }
}
