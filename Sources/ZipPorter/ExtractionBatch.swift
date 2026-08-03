import Foundation
import ZipPorterCore

/// One archive's contribution to a batch, flattened out of
/// `Unpacker.Result` so the reporting rules can be tested without an
/// extraction.
struct ArchiveOutcome: Equatable {
    var archive: String
    var rootName: String
    var files: Int
    var directories: Int
    var topItems: [URL] = []
    var unsafePaths: [String] = []
    var symlinks: Int = 0
    /// "original → chosen", already formatted.
    var renamed: [String] = []
    var quarantineFailures: [String] = []

    init(archive: String, rootName: String, files: Int, directories: Int) {
        self.archive = archive
        self.rootName = rootName
        self.files = files
        self.directories = directories
    }

    init(archive: String, result: Unpacker.Result) {
        self.init(archive: archive,
                  rootName: result.root.lastPathComponent,
                  files: result.extractedFiles,
                  directories: result.extractedDirectories)
        topItems = result.extractedTopItems
        unsafePaths = result.skippedUnsafe
        symlinks = result.skippedSymlinks.count
        renamed = result.renamedDuplicates.map { "\($0.original) → \($0.chosen)" }
        quarantineFailures = result.quarantineFailures
    }
}

/// What one request produced, accumulated across every archive in it.
///
/// A Finder multi-selection arrives as a single open event, and ADR-0004
/// makes it a single result: one summary, one set of notes, one Finder
/// reveal. Reporting each archive separately meant the user could only read
/// the last banner — macOS replaces one banner with the next from the same
/// app — while the rest queued up in Notification Center.
///
/// Pure and value-typed on purpose: which outcomes may be announced by a
/// banner and which must hold the user with a dialog is the part worth
/// testing.
struct ExtractionBatch {
    struct Failure: Equatable {
        var archive: String
        var reason: String
    }

    /// How many archives the user asked for — the denominator in
    /// "2 of 3 extracted", and what makes a shortfall visible at all.
    let requested: Int
    private(set) var outcomes: [ArchiveOutcome] = []
    private(set) var failures: [Failure] = []
    /// The user cancelled partway; archives after that point never ran.
    var cancelled = false

    /// At most this many individual lines per note before it collapses into
    /// a count. Truncation is always stated — a silently clipped list reads
    /// as a complete one.
    private static let listLimit = 6

    init(requested: Int) {
        self.requested = requested
    }

    mutating func record(_ outcome: ArchiveOutcome) { outcomes.append(outcome) }
    mutating func record(_ failure: Failure) { failures.append(failure) }

    var succeeded: Int { outcomes.count }
    var files: Int { outcomes.reduce(0) { $0 + $1.files } }
    var directories: Int { outcomes.reduce(0) { $0 + $1.directories } }
    /// Everything the batch created, for one Finder reveal at the end.
    var topItems: [URL] { outcomes.flatMap(\.topItems) }

    /// Nothing came out at all — the caller reports this as an error rather
    /// than as a result with zero in it.
    var isTotalFailure: Bool { outcomes.isEmpty && !failures.isEmpty }

    var title: String { L("Archive extracted") }

    var summary: String {
        let counts = String(format: L("%1$d files, %2$d folders"), files, directories)
        if requested == 1, let only = outcomes.first {
            return only.rootName + "\n" + counts
        }
        let headline = (failures.isEmpty && !cancelled)
            ? String(format: L("Extracted %d archives"), succeeded)
            : String(format: L("%1$d of %2$d archives extracted"), succeeded, requested)
        return headline + "\n" + counts
    }

    /// Everything the user must be told about rather than left to discover.
    /// Non-empty forces the dialog regardless of the completion-style
    /// setting (ADR-0001).
    var notes: [String] {
        var lines: [String] = []
        if !failures.isEmpty {
            lines.append(Self.list(L("Could not extract these archives:"),
                                   failures.map { "\($0.archive) — \($0.reason)" }))
        }
        let unsafePaths = outcomes.flatMap(\.unsafePaths)
        if !unsafePaths.isEmpty {
            lines.append(Self.list(L("Skipped entries with unsafe paths:"), unsafePaths))
        }
        let symlinks = outcomes.reduce(0) { $0 + $1.symlinks }
        if symlinks > 0 {
            lines.append(L("Skipped symbolic links:") + " \(symlinks)")
        }
        let renamed = outcomes.flatMap(\.renamed)
        if !renamed.isEmpty {
            lines.append(Self.list(L("Duplicate names were extracted under new names:"), renamed))
        }
        let quarantine = outcomes.flatMap(\.quarantineFailures)
        if !quarantine.isEmpty {
            // Gatekeeper will not evaluate what we failed to mark — the one
            // outcome the user cannot discover any other way.
            lines.append(Self.list(
                L("These items could not be marked as downloaded, so macOS will not check them:"),
                quarantine))
        }
        if cancelled {
            lines.append(L("Cancelled — the remaining archives were not extracted."))
        }
        return lines
    }

    /// Headline and detail for the "nothing extracted" alert.
    var failureHeadline: String {
        requested == 1
            ? L("Could not extract the archive.")
            : L("Could not extract these archives:")
    }

    var failureDetail: String {
        requested == 1
            ? (failures.first?.reason ?? "")
            : failures.map { "\($0.archive) — \($0.reason)" }.joined(separator: "\n")
    }

    private static func list(_ heading: String, _ items: [String]) -> String {
        var lines = items.prefix(listLimit).map { "  \($0)" }
        if items.count > listLimit {
            lines.append("  " + String(format: L("…and %d more"), items.count - listLimit))
        }
        return heading + "\n" + lines.joined(separator: "\n")
    }
}

/// Turns per-archive progress into one bar across the whole batch, weighted
/// by each archive's size on disk. Without it the bar restarts at zero for
/// every archive and never says how much of the request is left.
struct BatchProgress {
    private let sizes: [Double]
    private let total: Double

    init(sizes: [UInt64]) {
        let raw = sizes.map(Double.init)
        let sum = raw.reduce(0, +)
        // An all-empty batch would divide by zero; weigh the archives
        // equally and count them instead of their bytes.
        self.sizes = sum > 0 ? raw : raw.map { _ in 1 }
        total = sum > 0 ? sum : Double(max(1, raw.count))
    }

    /// Overall 0…1 given how far the archive at `index` has come.
    func overall(index: Int, fraction: Double) -> Double {
        guard index >= 0, index < sizes.count else { return 0 }
        let done = sizes.prefix(index).reduce(0, +)
        return min(1, (done + sizes[index] * max(0, min(1, fraction))) / total)
    }
}
