import XCTest

@testable import ZipPorter

/// Regression cover for the v0.10.0 launch crash: SwiftPM's `Bundle.module`
/// never looked in `Contents/Resources`, so a packaged .app only found its
/// localization bundle on the machine that built it.
final class ResourceBundleTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/ZipPorter.app")
    private let resources = URL(
        fileURLWithPath: "/Applications/ZipPorter.app/Contents/Resources")
    private let build = URL(fileURLWithPath: "/tmp/.build/release")

    func testAppResourcesDirectoryIsSearchedFirst() {
        let dirs = ResourceBundleLocator.searchDirectories(
            mainResourceURL: resources, mainBundleURL: app, codeDirectoryURL: build)
        XCTAssertEqual(dirs, [resources, app, build])
    }

    func testMissingDirectoriesAreSkipped() {
        let dirs = ResourceBundleLocator.searchDirectories(
            mainResourceURL: nil, mainBundleURL: app, codeDirectoryURL: nil)
        XCTAssertEqual(dirs, [app])
    }

    func testLocatesBundleInPackagedAppResources() {
        let found = ResourceBundleLocator.locate(
            bundleName: "ZipPorter_ZipPorter", in: [resources, app, build]
        ) { $0.path == "/Applications/ZipPorter.app/Contents/Resources/ZipPorter_ZipPorter.bundle" }
        XCTAssertEqual(
            found?.path,
            "/Applications/ZipPorter.app/Contents/Resources/ZipPorter_ZipPorter.bundle")
    }

    func testLocatesBundleBesideBareExecutable() {
        let found = ResourceBundleLocator.locate(
            bundleName: "ZipPorter_ZipPorter", in: [app, build]
        ) { $0.path == "/tmp/.build/release/ZipPorter_ZipPorter.bundle" }
        XCTAssertEqual(found?.path, "/tmp/.build/release/ZipPorter_ZipPorter.bundle")
    }

    func testReturnsNilWhenNoDirectoryHoldsTheBundle() {
        let found = ResourceBundleLocator.locate(
            bundleName: "ZipPorter_ZipPorter", in: [resources, app, build]) { _ in false }
        XCTAssertNil(found)
    }

    func testResolveFallsBackInsteadOfTrappingWhenBundleIsMissing() {
        let fallback = Bundle(for: ResourceBundleTests.self)
        XCTAssertEqual(
            ResourceBundleLocator.resolve(bundleName: "NoSuchBundle", fallback: fallback),
            fallback)
    }

    /// The real lookup must succeed in whatever layout the test run uses;
    /// otherwise every localized string silently falls back to its key.
    func testAppResourcesBundleResolvesToTheRealLocalizationBundle() {
        XCTAssertNotNil(Bundle.appResources.url(forResource: "ja", withExtension: "lproj"))
    }
}
