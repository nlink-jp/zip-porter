import Foundation

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
