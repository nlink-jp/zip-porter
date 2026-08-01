import Foundation

/// File-name encoding transforms for Windows round-trips (RFP §2).
///
/// macOS file APIs hand back decomposed UTF-8 (NFD), which Windows renders
/// as split dakuten ("テ゛ータ"); every name we store is NFC-normalized first.
/// CP932 (Windows-31J) is what Japanese Windows and legacy extraction tools
/// assume when the ZIP entry lacks the UTF-8 flag.
public enum FileNameTransform {
    /// CP932 (a.k.a. Windows-31J): Shift_JIS with Microsoft extensions.
    /// `String.Encoding.shiftJIS` alone rejects the MS extension characters
    /// (①, ㈱, ～ mapped the Windows way), so the CF DOS-Japanese encoding
    /// is required.
    public static let cp932: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        return String.Encoding(rawValue: cf)
    }()

    /// NFC-normalize a file name.
    public static func nfc(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Encode a name as CP932 bytes for a legacy-compatible entry header.
    /// Returns nil when the name contains characters CP932 cannot represent
    /// (the caller must surface this as a pack error, not silently mangle).
    public static func encodeCP932(_ name: String) -> Data? {
        nfc(name).data(using: cp932)
    }

    /// Decode CP932 entry-header bytes. Returns nil on undecodable sequences
    /// (the caller falls back to other encodings per the auto-detect order).
    public static func decodeCP932(_ bytes: Data) -> String? {
        String(data: bytes, encoding: cp932)
    }
}
