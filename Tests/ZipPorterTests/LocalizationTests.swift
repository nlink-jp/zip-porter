import XCTest
@testable import ZipPorter

/// en/ja key-set parity, and en as an identity table. New L() keys must be
/// added to BOTH Localizable.strings files.
final class LocalizationTests: XCTestCase {
    private func stringsTable(_ localization: String) throws -> [String: String] {
        let bundle = L10nResources.bundle
        let path = try XCTUnwrap(
            bundle.path(forResource: "Localizable", ofType: "strings",
                        inDirectory: nil, forLocalization: localization),
            "\(localization).lproj/Localizable.strings missing")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    func testKeySetsMatch() throws {
        let en = try stringsTable("en")
        let ja = try stringsTable("ja")
        let missingInJa = Set(en.keys).subtracting(ja.keys).sorted()
        let missingInEn = Set(ja.keys).subtracting(en.keys).sorted()
        XCTAssertEqual(missingInJa, [], "keys missing from ja.lproj")
        XCTAssertEqual(missingInEn, [], "keys missing from en.lproj")
    }

    func testEnglishIsIdentityTable() throws {
        for (key, value) in try stringsTable("en") {
            XCTAssertEqual(key, value, "en.lproj must map keys to themselves")
        }
    }

    func testJapaneseValuesAreTranslated() throws {
        let ja = try stringsTable("ja")
        // Not every value differs (e.g. "OK"), but most must.
        let translated = ja.filter { $0.key != $0.value }.count
        XCTAssertGreaterThan(translated, ja.count / 2)
    }
}
