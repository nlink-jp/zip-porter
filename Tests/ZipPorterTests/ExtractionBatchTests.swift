import XCTest
@testable import ZipPorter

/// How a whole request reports itself (ADR-016). The bug this replaces:
/// three archives opened from one Finder selection produced three banners,
/// each replacing the last, so the user could read about exactly one of
/// them.
final class ExtractionBatchTests: XCTestCase {
    private func outcome(_ name: String, files: Int = 2, directories: Int = 1) -> ArchiveOutcome {
        ArchiveOutcome(archive: "\(name).zip", rootName: name,
                       files: files, directories: directories)
    }

    // MARK: - Summary

    func testSingleArchiveKeepsItsOwnWording() {
        var batch = ExtractionBatch(requested: 1)
        batch.record(outcome("report", files: 5, directories: 2))
        XCTAssertTrue(batch.summary.hasPrefix("report\n"), batch.summary)
        XCTAssertTrue(batch.summary.contains("5"))
        XCTAssertTrue(batch.notes.isEmpty)
    }

    func testCleanBatchIsCountedOnce() {
        var batch = ExtractionBatch(requested: 3)
        for name in ["a", "b", "c"] { batch.record(outcome(name, files: 4, directories: 1)) }
        XCTAssertEqual(batch.succeeded, 3)
        XCTAssertEqual(batch.files, 12)
        XCTAssertEqual(batch.directories, 3)
        // Totals, not the last archive's name.
        XCTAssertFalse(batch.summary.contains("c\n"))
        XCTAssertTrue(batch.notes.isEmpty, "a clean batch may be announced by a banner")
    }

    /// A shortfall must be visible in the headline; "extracted 2 archives"
    /// when three were asked for is the failure this guards.
    func testPartialBatchStatesTheDenominator() {
        var batch = ExtractionBatch(requested: 3)
        batch.record(outcome("a"))
        batch.record(outcome("b"))
        batch.record(ExtractionBatch.Failure(archive: "c.zip", reason: "damaged"))
        XCTAssertTrue(batch.summary.contains("2"), batch.summary)
        XCTAssertTrue(batch.summary.contains("3"), batch.summary)
        XCTAssertFalse(batch.notes.isEmpty, "a failure must hold the user with a dialog")
        XCTAssertTrue(batch.notes.joined().contains("c.zip — damaged"))
    }

    func testTotalFailureIsAnErrorNotAResult() {
        var batch = ExtractionBatch(requested: 2)
        batch.record(ExtractionBatch.Failure(archive: "a.zip", reason: "damaged"))
        batch.record(ExtractionBatch.Failure(archive: "b.zip", reason: "not a ZIP"))
        XCTAssertTrue(batch.isTotalFailure)
        XCTAssertTrue(batch.failureDetail.contains("a.zip"))
        XCTAssertTrue(batch.failureDetail.contains("b.zip"))
    }

    func testSingleFailureReportsOnlyItsReason() {
        var batch = ExtractionBatch(requested: 1)
        batch.record(ExtractionBatch.Failure(archive: "a.zip", reason: "not a ZIP"))
        XCTAssertTrue(batch.isTotalFailure)
        XCTAssertEqual(batch.failureDetail, "not a ZIP")
    }

    // MARK: - Notes

    /// ADR-012: security-relevant outcomes are never announced by a banner.
    /// Merged across the batch so one dialog covers the whole request.
    func testSecurityNotesMergeAcrossArchives() {
        var batch = ExtractionBatch(requested: 2)
        var first = outcome("a")
        first.unsafePaths = ["../escape.txt"]
        first.symlinks = 2
        var second = outcome("b")
        second.symlinks = 3
        second.quarantineFailures = ["b/App.app"]
        batch.record(first)
        batch.record(second)

        let notes = batch.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("../escape.txt"))
        XCTAssertTrue(notes.contains("b/App.app"))
        XCTAssertTrue(notes.contains("5"), "symlink counts add up across the batch: \(notes)")
    }

    /// A clipped list that does not say it was clipped reads as complete.
    func testLongListsSayHowManyWereNotShown() {
        var batch = ExtractionBatch(requested: 1)
        var only = outcome("a")
        only.unsafePaths = (1...10).map { "../escape\($0).txt" }
        batch.record(only)
        let notes = batch.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("../escape1.txt"))
        XCTAssertFalse(notes.contains("../escape10.txt"))
        XCTAssertTrue(notes.contains("4"), "four unshown entries must be stated: \(notes)")
    }

    func testCancellationIsReportedRatherThanLookingLikeCompletion() {
        var batch = ExtractionBatch(requested: 3)
        batch.record(outcome("a"))
        batch.cancelled = true
        XCTAssertFalse(batch.notes.isEmpty)
        XCTAssertTrue(batch.summary.contains("1"))
        XCTAssertTrue(batch.summary.contains("3"))
    }

    // MARK: - Reveal

    func testRevealTargetsCoverTheWholeBatch() {
        var batch = ExtractionBatch(requested: 2)
        var first = outcome("a")
        first.topItems = [URL(fileURLWithPath: "/tmp/a")]
        var second = outcome("b")
        second.topItems = [URL(fileURLWithPath: "/tmp/b1"), URL(fileURLWithPath: "/tmp/b2")]
        batch.record(first)
        batch.record(second)
        XCTAssertEqual(batch.topItems.count, 3)
    }

    // MARK: - Progress

    func testProgressIsWeightedByArchiveSize() {
        // A 90 MB archive followed by a 10 MB one: finishing the first is
        // 90 % of the request, not 50 %.
        let progress = BatchProgress(sizes: [90, 10])
        XCTAssertEqual(progress.overall(index: 0, fraction: 0), 0, accuracy: 0.001)
        XCTAssertEqual(progress.overall(index: 0, fraction: 1), 0.9, accuracy: 0.001)
        XCTAssertEqual(progress.overall(index: 1, fraction: 0), 0.9, accuracy: 0.001)
        XCTAssertEqual(progress.overall(index: 1, fraction: 1), 1.0, accuracy: 0.001)
    }

    func testProgressNeverGoesBackwardsBetweenArchives() {
        let progress = BatchProgress(sizes: [10, 10, 10])
        var last = -1.0
        for index in 0..<3 {
            for step in stride(from: 0.0, through: 1.0, by: 0.25) {
                let value = progress.overall(index: index, fraction: step)
                XCTAssertGreaterThanOrEqual(value, last)
                last = value
            }
        }
        XCTAssertEqual(last, 1.0, accuracy: 0.001)
    }

    /// Empty archives would divide by zero; the bar falls back to counting.
    func testZeroSizedBatchStillAdvances() {
        let progress = BatchProgress(sizes: [0, 0])
        XCTAssertEqual(progress.overall(index: 0, fraction: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(progress.overall(index: 1, fraction: 1), 1.0, accuracy: 0.001)
    }

    func testOutOfRangeIndexIsNotAcrash() {
        let progress = BatchProgress(sizes: [10])
        XCTAssertEqual(progress.overall(index: 5, fraction: 1), 0)
    }
}
