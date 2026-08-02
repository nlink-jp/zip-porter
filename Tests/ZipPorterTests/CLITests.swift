import XCTest
@testable import ZipPorter

final class CLITests: XCTestCase {
    func testNoArgumentsLaunchesGUI() {
        XCTAssertEqual(CLI.parse(["zip-porter"]), .gui)
    }

    func testVersionFlag() {
        XCTAssertEqual(CLI.parse(["zip-porter", "--version"]), .version)
    }

    func testSubcommandsCarryTheirArguments() {
        XCTAssertEqual(
            CLI.parse(["zip-porter", "pack", "docs", "-o", "docs.zip"]),
            .pack(args: ["docs", "-o", "docs.zip"]))
        XCTAssertEqual(
            CLI.parse(["zip-porter", "unpack", "a.zip"]),
            .unpack(args: ["a.zip"]))
        XCTAssertEqual(
            CLI.parse(["zip-porter", "inspect", "a.zip"]),
            .inspect(args: ["a.zip"]))
    }

    func testUnknownBareWordIsAnError() {
        XCTAssertEqual(CLI.parse(["zip-porter", "compress"]), .unknown("compress"))
    }

    func testMacOSLaunchArgumentsFallThroughToGUI() {
        // Finder / LaunchServices inject flag-style argv the CLI must ignore.
        XCTAssertEqual(CLI.parse(["zip-porter", "-psn_0_12345"]), .gui)
        XCTAssertEqual(CLI.parse(["zip-porter", "-NSDocumentRevisionsDebugMode", "YES"]), .gui)
    }

    /// The cask exposes the CLI as a symlink into the bundle, where
    /// Bundle.main is not the .app; the version must still resolve from the
    /// Info.plist beside the real executable (it read "dev" in v0.9.2).
    func testVersionResolvesThroughASymlinkedExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-bundle-\(UUID().uuidString)")
        let macos = root.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("Fake.app/Contents/Info.plist")
        try (["CFBundleShortVersionString": "9.9.9"] as NSDictionary).write(to: plist)

        let executable = macos.appendingPathComponent("Fake")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        let link = root.appendingPathComponent("fake-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        // Same walk AppInfo performs: symlink → …/Contents/Info.plist.
        let resolved = link.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: resolved))
        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, "9.9.9")
    }

    func testVersionNormalizeStripsLeadingV() {
        XCTAssertEqual(AppInfo.normalize("v0.1.0"), "0.1.0")
        XCTAssertEqual(AppInfo.normalize("0.1.0"), "0.1.0")
    }
}
