import Foundation

/// File-name encoding of ZIP entries that lack the UTF-8 flag (bit 11).
public enum NameEncoding: String, Sendable, Equatable {
    case utf8
    case cp932
}

public enum EncodingDetector {
    /// Decide the archive-wide encoding for entries without the UTF-8 flag.
    ///
    /// UTF-8 validation runs FIRST: CP932 Japanese text is almost never valid
    /// UTF-8 (its lead bytes land on UTF-8 continuation values), while UTF-8
    /// Japanese bytes usually *do* decode as CP932 — as mojibake. A
    /// CP932-first order would therefore misread modern unflagged archives;
    /// UTF-8-first misreads essentially nothing.
    public static func detect(_ rawNames: [Data]) -> NameEncoding {
        let nonASCII = rawNames.filter { name in name.contains { $0 >= 0x80 } }
        guard !nonASCII.isEmpty else { return .utf8 }
        if nonASCII.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) {
            return .utf8
        }
        return .cp932
    }

    /// Decode raw name bytes. Falls back across encodings rather than failing:
    /// a ZIP with undecodable names must still be listable and extractable.
    public static func decode(_ raw: Data, as encoding: NameEncoding) -> String {
        switch encoding {
        case .utf8:
            if let s = String(data: raw, encoding: .utf8) { return s }
            if let s = FileNameTransform.decodeCP932(raw) { return s }
        case .cp932:
            if let s = FileNameTransform.decodeCP932(raw) { return s }
            if let s = String(data: raw, encoding: .utf8) { return s }
        }
        // Latin-1 maps every byte; garbled but lossless and never nil.
        return String(data: raw, encoding: .isoLatin1)
            ?? raw.map { String(format: "%%%02X", $0) }.joined()
    }
}
