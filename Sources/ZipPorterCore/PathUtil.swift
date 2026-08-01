import Foundation

public enum PathUtil {
    /// Return `url` if nothing exists there, else "name 2", "name 3", …
    /// (Archive Utility's collision style). The numbered suffix goes before
    /// the extension: "report.zip" → "report 2.zip".
    public static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(stem) \(n)")
                : dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
