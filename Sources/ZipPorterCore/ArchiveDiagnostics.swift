import Foundation

/// The failure report's view of an archive (ADR-0007): its structure as
/// counts and numbers, so a developer can tell which writer made it and
/// which shape of entry failed — without a single name in it. Names, the
/// archive comment, and extra-field *contents* are never read here; the
/// people who send these reports are the ones who cannot share the file.
/// Nor are CRCs and timestamps: a CRC fingerprints the content, and a time
/// says when the work was done.
///
/// Pure, fixed-format English: the reader is the developer, comparing
/// reports from different people.
public enum ArchiveDiagnostics {
    public static func lines(entries: [ZipEntry], archiveSize: UInt64,
                             hasZip64Directory: Bool, failingEntry: Int?) -> [String] {
        let directories = entries.filter(\.isDirectory).count
        var lines = [
            "size: \(archiveSize) bytes, \(entries.count) entries (\(directories) directories), "
                + "zip64 directory: \(hasZip64Directory ? "yes" : "no")",
            "methods: " + tally(entries.map { method($0.method) }),
            "encryption: " + tally(entries.map { encryption($0.encryption) }),
            "made by: " + tally(entries.map { madeBy($0.versionMadeBy) }),
            "version needed: " + tally(entries.map { version($0.versionNeeded) }),
            "flags: data descriptor x\(entries.filter { $0.flags.contains(.dataDescriptor) }.count), "
                + "utf-8 names x\(entries.filter { $0.flags.contains(.utf8Name) }.count)",
            "extra fields: " + tally(entries.flatMap { entry in
                entry.extraFieldIDs.map { Set($0).sorted().map(hex) } ?? ["malformed"]
            }),
        ]
        if let index = failingEntry, entries.indices.contains(index) {
            let entry = entries[index]
            lines.append("failing entry: #\(index + 1) of \(entries.count)"
                         + (entry.isDirectory ? " (directory)" : ""))
            lines.append("  method \(entry.method.rawValue), \(encryption(entry.encryption)), "
                         + "flags \(hex(entry.flags.rawValue))")
            lines.append("  made by \(madeBy(entry.versionMadeBy)), needs \(version(entry.versionNeeded))")
            lines.append("  \(entry.compressedSize) -> \(entry.uncompressedSize) bytes")
            lines.append("  extra fields: " + extraFields(entry.extraFieldIDs))
        }
        return lines
    }

    /// "a x2, b x1" — most frequent first, ties in label order, so two
    /// reports of the same archive read the same.
    static func tally(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "none" }
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) x\($0.value)" }
            .joined(separator: ", ")
    }

    static func method(_ method: Zip.Method) -> String {
        switch method {
        case .store: return "store (0)"
        case .deflate: return "deflate (8)"
        case .deflate64: return "deflate64 (9)"
        case .aes: return "aes (99)"
        case .other(let raw): return "method \(raw)"
        }
    }

    static func encryption(_ encryption: Zip.Encryption) -> String {
        switch encryption {
        case .none: return "none"
        case .zipCrypto: return "zipcrypto"
        case .aes(let strength, let vendor, let actual):
            return "aes\(strength.keyBytes * 8)/ae-\(vendor) inner method \(actual)"
        }
    }

    /// Host system (upper byte, APPNOTE 4.4.2) and spec version (lower).
    static func madeBy(_ versionMadeBy: UInt16) -> String {
        let host = Int(versionMadeBy >> 8)
        return "\(hostName(host)) \(version(versionMadeBy & 0xFF))"
    }

    static func version(_ value: UInt16) -> String {
        let spec = Int(value & 0xFF)
        return "\(spec / 10).\(spec % 10)"
    }

    static func hostName(_ host: Int) -> String {
        switch host {
        case 0: return "fat"
        case 3: return "unix"
        case 7: return "macintosh"
        case 10: return "ntfs"
        case 14: return "vfat"
        case 19: return "osx"
        default: return "host \(host)"
        }
    }

    static func extraFields(_ ids: [UInt16]?) -> String {
        guard let ids else { return "malformed" }
        return ids.isEmpty ? "none" : ids.map(hex).joined(separator: " ")
    }

    static func hex(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
    }
}
