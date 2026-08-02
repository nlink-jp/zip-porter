import Foundation

/// Locates the SwiftPM-generated resource bundle (`ZipPorter_ZipPorter.bundle`)
/// at runtime.
///
/// SwiftPM's own `Bundle.module` accessor tries only two paths: `<name>.bundle`
/// directly beside `Bundle.main.bundleURL` — right for a bare CLI executable,
/// wrong for an `.app`, where `make build-app` installs it into
/// `Contents/Resources` — and, failing that, the absolute `.build` path baked
/// in at compile time. Inside a packaged app only the second path ever matched,
/// so `Bundle.module` worked on the machine that built it and trapped at launch
/// anywhere else (v0.10.0 and earlier).
enum ResourceBundleLocator {
    /// Directories that may hold `<bundleName>.bundle`, in search order.
    ///
    /// - `mainResourceURL`: `Contents/Resources` of a packaged `.app`.
    /// - `mainBundleURL`: the directory holding a bare executable (`swift run`).
    /// - `codeDirectoryURL`: the directory holding the compiled code bundle,
    ///   which is where SwiftPM stages resources for `swift test`.
    static func searchDirectories(
        mainResourceURL: URL?,
        mainBundleURL: URL?,
        codeDirectoryURL: URL?
    ) -> [URL] {
        [mainResourceURL, mainBundleURL, codeDirectoryURL].compactMap { $0 }
    }

    /// First directory in `directories` that actually contains
    /// `<bundleName>.bundle`, or nil when none does.
    static func locate(
        bundleName: String,
        in directories: [URL],
        exists: (URL) -> Bool
    ) -> URL? {
        directories
            .map { $0.appending(path: "\(bundleName).bundle") }
            .first(where: exists)
    }

    /// The resource bundle named `bundleName`, or `fallback` when it cannot be
    /// found. A missing localization table degrades to the English keys, which
    /// are the source strings — far better than trapping at launch.
    static func resolve(bundleName: String, fallback: Bundle = .main) -> Bundle {
        let directories = searchDirectories(
            mainResourceURL: Bundle.main.resourceURL,
            mainBundleURL: Bundle.main.bundleURL,
            codeDirectoryURL: Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent()
        )
        let found = locate(bundleName: bundleName, in: directories) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return found.flatMap(Bundle.init(url:)) ?? fallback
    }

    /// Anchor class used only to ask Foundation which image this code lives in.
    private final class BundleFinder {}
}

extension Bundle {
    /// The app target's resource bundle (en/ja `Localizable.strings`).
    static let appResources = ResourceBundleLocator.resolve(
        bundleName: "ZipPorter_ZipPorter")
}
