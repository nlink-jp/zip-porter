import XCTest
@testable import ZipPorterCore

/// Structural pins for the root-cause classes of ADR-0005. Each behaviour
/// test elsewhere covers one instance; these read the engine's source and
/// fail when a second instance of a class is introduced — a new removal
/// site, a second derivation of an offset, a second scratch-file lifecycle.
final class ArchitectureTests: XCTestCase {
    private static let engineSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ZipPorterCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/ZipPorterCore")

    /// The file's code lines — comment lines dropped, so a doc comment that
    /// names the forbidden call to explain why it is forbidden does not
    /// count as an occurrence.
    private func source(_ file: String) throws -> String {
        try String(contentsOf: Self.engineSources.appendingPathComponent(file), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - Class A: ownership is recorded at creation, released from one place

    func testExtractionRemovesFilesOnlyThroughTheOwnershipLedger() throws {
        // Every deletion the extractor performs goes through
        // OwnedItems.removeAll, whose contents come from exclusive creates.
        // A `removeItem` anywhere in Unpacker would be a second remover
        // that can only reason from planned names.
        let unpacker = try source("Unpacker.swift")
        XCTAssertEqual(occurrences(of: "removeItem(", in: unpacker), 0,
                       "Unpacker must not delete anything itself; only OwnedItems.removeAll may")
        XCTAssertGreaterThan(occurrences(of: "owned.removeAll()", in: unpacker), 0)
        XCTAssertEqual(occurrences(of: "createDirectory(at: wrapper", in: unpacker), 0,
                       "top-level items are created with the exclusive helpers, never the permissive call")
    }

    func testUniquenessChecksAndExclusiveCreatesAgreeOnWhatExists() throws {
        // `fileExists(atPath:)` follows symlinks and calls a dangling one
        // absent; mkdir/O_EXCL do not. The name-picking side must use the
        // lstat answer, or the two disagree on the very case that matters.
        let unpacker = try source("Unpacker.swift")
        let pathUtil = try source("PathUtil.swift")
        XCTAssertEqual(occurrences(of: "fileExists(atPath: destBase.appendingPathComponent", in: unpacker), 0,
                       "top-level uniqueness must go through PathUtil.somethingExists (lstat)")
        XCTAssertEqual(occurrences(of: "fileExists(", in: pathUtil), 0,
                       "PathUtil's existence answers are lstat-based")
    }

    func testCompressionScratchHasOneLifecycle() throws {
        // One arena per compress call: opened in one place, removed in one
        // place. A second open or a second `removeItem` would be a second
        // lifecycle to keep straight on every exit path — the shape of the
        // per-entry scratch files this replaced.
        let compressor = try source("ParallelCompressor.swift")
        XCTAssertEqual(occurrences(of: "openScratch(", in: compressor), 1, "the arena opens its file once")
        XCTAssertEqual(occurrences(of: "createExclusively(", in: compressor), 1, "the default opener")
        XCTAssertEqual(occurrences(of: "removeItem(", in: compressor), 1, "ScratchArena.remove is the only remover")
        XCTAssertEqual(occurrences(of: "static var", in: compressor), 0,
                       "knobs travel in Limits, passed per call — no process-wide state for tests to mutate")
    }

    // MARK: - Class B: one derivation of the entry data offset

    func testEntryDataOffsetIsDerivedExactlyOnce() throws {
        // The local header's name and extra lengths (fields at 26 and 28)
        // are read in one place; `extract` consumes `dataOffset` and reads
        // no header. A second read of either field is a second derivation.
        let reader = try source("ZipReader.swift")
        XCTAssertEqual(occurrences(of: "readU16(at: 26)", in: reader), 1, "local name length read once")
        XCTAssertEqual(occurrences(of: "readU16(at: 28)", in: reader), 1, "local extra length read once")
        XCTAssertEqual(occurrences(of: ".dataOffset =", in: reader), 1, "dataOffset assigned in one place")
    }

    // MARK: - ADR-0007: error details never carry a name

    func testErrorDetailsNeverInterpolateANameOrPath() throws {
        // The failure report prints `corrupt` and `entryCorrupt` details and
        // Inflate64's reasons verbatim; names belong in the labeled
        // `entryName` field, which the report leaves out. A detail built
        // with a name, path or URL interpolated is how a name would reach a
        // report the person forwards without reading.
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.engineSources.path)
            .filter { $0.hasSuffix(".swift") }
        let carriers = ["ZipReaderError.corrupt(", "detail:", ".invalid("]
        let forbidden = try NSRegularExpression(pattern: #"\\\([^)]*(name|Name|path|Path|url|URL)"#)
        var offenders: [String] = []
        for file in files {
            for line in try source(file).split(separator: "\n") {
                let text = String(line)
                guard carriers.contains(where: text.contains) else { continue }
                if forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    offenders.append("\(file): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "put the name in `entryName`, keep the detail name-free")
    }
}
