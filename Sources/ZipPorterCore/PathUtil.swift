import Darwin
import Foundation

/// Byte-based progress for pack/unpack, so a UI can draw a real bar
/// instead of an indeterminate spinner.
public struct OperationProgress: Sendable {
    public var currentPath: String
    public var processedBytes: UInt64
    public var totalBytes: UInt64

    public var fraction: Double {
        totalBytes == 0 ? 0 : min(1, Double(processedBytes) / Double(totalBytes))
    }
}

public enum PathUtil {
    /// "name" → "name 2", "name 3", … with the number before the extension
    /// ("report.zip" → "report 2.zip") — Archive Utility's collision style.
    public static func numberedVariant(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    /// First name (starting from `name` itself) for which `isTaken` is false.
    public static func uniqueName(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var n = 2
        while isTaken(numberedVariant(name, n)) { n += 1 }
        return numberedVariant(name, n)
    }

    /// Create a file and hand back a write handle, refusing to touch
    /// anything already at that path.
    ///
    /// `FileManager.createFile` truncates whatever it finds, which would
    /// leave the "never overwrite" rule resting on the gap between
    /// `uniqueName`'s existence check and the write. `O_EXCL` closes that
    /// gap: a racing creation now fails the extraction instead of eating
    /// the file. `permissions` goes through the umask like any other
    /// `open(2)`; the archive's own mode, when it has one, is applied
    /// afterwards by `PosixPermissions`.
    public static func createExclusively(at url: URL,
                                         permissions: mode_t = 0o666) throws -> FileHandle {
        var descriptor: Int32 = -1
        var failure: Int32 = EINVAL
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, permissions)
            if descriptor < 0 { failure = errno }
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): \(String(cString: strerror(failure)))",
            ])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Create a directory, refusing to touch anything already at that path.
    ///
    /// `FileManager.createDirectory(withIntermediateDirectories: true)`
    /// treats an existing directory as success, which would let an
    /// extraction pour its entries into a folder some other process just
    /// made — and then delete that folder on failure. `mkdir(2)` fails with
    /// `EEXIST` on anything at the path, dangling symlinks included, so
    /// success here means *this call* created the directory (ADR-0005).
    /// `permissions` goes through the umask like any other `mkdir(2)`.
    public static func createDirectoryExclusively(at url: URL,
                                                  permissions: mode_t = 0o777) throws {
        var failure: Int32 = 0
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { failure = EINVAL; return }
            if mkdir(path, permissions) != 0 { failure = errno }
        }
        guard failure == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure), userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): \(String(cString: strerror(failure)))",
            ])
        }
    }

    /// Return `url` if nothing exists there, else the numbered variant.
    public static func uniqueURL(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = uniqueName(url.lastPathComponent) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }
}

/// Filesystem items one operation has brought into existence, recorded only
/// after the creating call returned success. A failure path removes what
/// the ledger holds and nothing else — it has no view of what was *planned*
/// — so a name another process took in the meantime is never deleted on
/// its behalf (ADR-0005).
struct OwnedItems {
    private(set) var urls: [URL] = []

    mutating func adopt(_ url: URL) {
        urls.append(url)
    }

    /// Remove every owned item, most recent first. Best-effort: an item
    /// that is already gone is not an error here.
    func removeAll() {
        for url in urls.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
