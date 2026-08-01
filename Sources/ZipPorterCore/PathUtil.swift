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

    /// Return `url` if nothing exists there, else the numbered variant.
    public static func uniqueURL(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = uniqueName(url.lastPathComponent) {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }
}
