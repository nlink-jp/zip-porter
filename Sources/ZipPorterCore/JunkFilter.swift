import Foundation

/// Filters macOS metadata that must not leak into a Windows-bound ZIP
/// (RFP §2 pack defaults). `pack --no-clean` bypasses this filter.
public struct JunkFilter: Sendable {
    /// Exact component names excluded anywhere in a path. "Icon\r" is the
    /// Finder custom-icon file (trailing CR is part of the real file name).
    public static let junkNames: Set<String> = [
        ".DS_Store",
        "__MACOSX",
        "Icon\r",
        ".fseventsd",
        ".Spotlight-V100",
        ".Trashes",
    ]

    public init() {}

    /// `path` is a slash-separated archive-relative path. A path is junk when
    /// any component matches the exclusion list or is an AppleDouble ("._*")
    /// sidecar — matching per component also drops whole `__MACOSX/` subtrees.
    public func isJunk(_ path: String) -> Bool {
        for component in path.split(separator: "/") {
            if Self.junkNames.contains(String(component)) { return true }
            if component.hasPrefix("._") { return true }
        }
        return false
    }
}
