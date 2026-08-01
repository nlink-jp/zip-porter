import XCTest
@testable import ZipPorterCore

final class JunkFilterTests: XCTestCase {
    let filter = JunkFilter()

    func testDSStoreAtRootIsJunk() {
        XCTAssertTrue(filter.isJunk(".DS_Store"))
    }

    func testDSStoreNestedIsJunk() {
        XCTAssertTrue(filter.isJunk("docs/sub/.DS_Store"))
    }

    func testAppleDoubleSidecarIsJunk() {
        XCTAssertTrue(filter.isJunk("._report.pdf"))
        XCTAssertTrue(filter.isJunk("docs/._report.pdf"))
    }

    func testMacOSXSubtreeIsJunk() {
        XCTAssertTrue(filter.isJunk("__MACOSX/docs/report.pdf"))
    }

    func testFinderIconFileIsJunk() {
        XCTAssertTrue(filter.isJunk("docs/Icon\r"))
    }

    func testSpotlightAndFseventsAreJunk() {
        XCTAssertTrue(filter.isJunk(".fseventsd/log"))
        XCTAssertTrue(filter.isJunk(".Spotlight-V100/x"))
        XCTAssertTrue(filter.isJunk(".Trashes/501/f.txt"))
    }

    func testOrdinaryFilesPass() {
        XCTAssertFalse(filter.isJunk("docs/report.pdf"))
        XCTAssertFalse(filter.isJunk("日本語フォルダ/資料.xlsx"))
    }

    func testLookalikesPass() {
        // Not an exact match / not a component prefix — these are user files.
        XCTAssertFalse(filter.isJunk("DS_Store")) // no leading dot
        XCTAssertFalse(filter.isJunk("Icon")) // without the trailing CR
        XCTAssertFalse(filter.isJunk("my.DS_Store.bak"))
    }

    func testUnderscoreDotMidNamePasses() {
        // "._" only counts as a component *prefix* (AppleDouble), not mid-name.
        XCTAssertFalse(filter.isJunk("report._final.pdf"))
        XCTAssertFalse(filter.isJunk("data._v2/readme.md"))
    }
}
