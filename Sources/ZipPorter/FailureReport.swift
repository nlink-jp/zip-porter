import Foundation
import ZipPorterCore

/// The text behind "Copy Details" and `unpack --report` (ADR-0007): what
/// failed and the archive's structure, for the developer — never a file
/// name, entry name, path, content, or password. The people who send these
/// are the ones who cannot share the archive, so the report must be safe to
/// forward without reading it first.
///
/// Fixed-format ASCII English, assembled by pure functions; the only I/O is
/// `structure(of:failingEntry:)`, which re-reads the central directory.
enum FailureReport {
    struct Environment: Equatable {
        var appVersion: String
        var osVersion: String

        static var current: Environment {
            Environment(appVersion: AppInfo.version, osVersion: osVersion())
        }

        /// "27.2.0 (26B123)". Built from numbers: the ready-made
        /// `operatingSystemVersionString` is localized ("バージョン27.2…"),
        /// and the report is fixed-format English.
        static func osVersion() -> String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            var size = 0
            sysctlbyname("kern.osversion", nil, &size, nil, 0)
            var build = [CChar](repeating: 0, count: max(size, 1))
            let ok = size > 0 && sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0
            let suffix = ok ? " (\(String(cString: build)))" : ""
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(suffix)"
        }
    }

    /// One failed archive's part of a report, already rendered.
    struct Section: Equatable {
        /// 0-based position in the request; the report counts from 1.
        var position: Int
        var lines: [String]
    }

    static func compose(environment: Environment, operation: String,
                        requested: Int, sections: [Section]) -> String {
        var lines = [
            "ZipPorter failure report",
            "version: \(environment.appVersion)",
            "macOS: \(environment.osVersion)",
            "operation: \(operation), \(requested) requested, \(sections.count) failed",
        ]
        for section in sections {
            lines.append("")
            lines.append("archive \(section.position + 1) of \(requested)")
            lines.append(contentsOf: section.lines.map { "  " + $0 })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An archive's section: the error, then its structure — or a note that
    /// the structure could not be read, in which case the error line holds
    /// what the parser saw.
    static func section(position: Int, error: String, structure: [String]?) -> Section {
        Section(position: position,
                lines: ["error: \(error)"] + (structure ?? ["structure: unreadable"]))
    }

    /// The archive's structure from a fresh read of its central directory —
    /// that alone, so an archive refused for its local headers or
    /// overlapping ranges is still described; nil when even the directory
    /// does not parse.
    static func structure(of zipURL: URL, failingEntry: Int?) -> [String]? {
        guard let directory = try? ZipReader.centralDirectory(of: zipURL) else { return nil }
        return ArchiveDiagnostics.lines(entries: directory.entries,
                                        archiveSize: directory.archiveSize,
                                        hasZip64Directory: directory.hasZip64Directory,
                                        failingEntry: failingEntry)
    }

    /// The error as a developer reads it: type and case, plus only the
    /// payload that cannot hold a name. Exhaustive over ZipPorter's own
    /// errors on purpose — a new case does not compile until someone has
    /// decided what it may report.
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as ZipReaderError:
            switch e {
            case .notAZipFile: return "ZipReaderError.notAZipFile"
            // `corrupt` details are offsets and fixed phrases; damage tied
            // to an entry is `entryCorrupt`, whose name stays out.
            case .corrupt(let detail): return "ZipReaderError.corrupt: \(detail)"
            case .entryCorrupt(_, let detail): return "ZipReaderError.entryCorrupt: \(detail)"
            case .unsupportedMethod(let method): return "ZipReaderError.unsupportedMethod(\(method))"
            case .unsupportedFeature: return "ZipReaderError.unsupportedFeature"
            case .passwordRequired: return "ZipReaderError.passwordRequired"
            case .wrongPassword: return "ZipReaderError.wrongPassword"
            case .crcMismatch: return "ZipReaderError.crcMismatch"
            case .authenticationFailed: return "ZipReaderError.authenticationFailed"
            case .sizeExceedsDeclared: return "ZipReaderError.sizeExceedsDeclared"
            case .overlappingEntries: return "ZipReaderError.overlappingEntries"
            }
        case let e as ZipWriterError:
            switch e {
            case .nameNotEncodable: return "ZipWriterError.nameNotEncodable"
            case .nameTooLong: return "ZipWriterError.nameTooLong"
            case .duplicateName: return "ZipWriterError.duplicateName"
            case .randomFailure: return "ZipWriterError.randomFailure"
            // The detail quotes file names and Foundation's sentences.
            case .ioError: return "ZipWriterError.ioError"
            }
        case let e as Unpacker.Failure:
            switch e {
            case .emptyArchive: return "Unpacker.Failure.emptyArchive"
            case .destinationNotADirectory: return "Unpacker.Failure.destinationNotADirectory"
            case .insufficientSpace(let required, let available):
                return "Unpacker.Failure.insufficientSpace(required: \(required), available: \(available))"
            }
        case let e as Packer.Failure:
            switch e {
            case .inputNotFound: return "Packer.Failure.inputNotFound"
            case .nothingToPack: return "Packer.Failure.nothingToPack"
            }
        default:
            return nsErrorChain(error as NSError)
        }
    }

    /// Domain and code down the underlying-error chain. Never the
    /// description or userInfo: Foundation quotes the file it failed on.
    static func nsErrorChain(_ error: NSError) -> String {
        var parts: [String] = []
        var current: NSError? = error
        while let e = current, parts.count < 4 {
            parts.append("\(e.domain) \(e.code)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }
}
