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

    func testVersionNormalizeStripsLeadingV() {
        XCTAssertEqual(AppInfo.normalize("v0.1.0"), "0.1.0")
        XCTAssertEqual(AppInfo.normalize("0.1.0"), "0.1.0")
    }
}
