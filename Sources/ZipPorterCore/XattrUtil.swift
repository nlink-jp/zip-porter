import Darwin
import Foundation

/// Extended-attribute access, used to propagate `com.apple.quarantine` from
/// a downloaded archive onto everything extracted from it (ADR-0001 §4).
/// Without this, Gatekeeper never evaluates executables that arrive inside
/// a ZIP — the behavior Archive Utility and The Unarchiver both provide.
public enum XattrUtil {
    public static let quarantineKey = "com.apple.quarantine"

    public static func value(of key: String, at path: String) -> Data? {
        let size = getxattr(path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, key, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read == size else { return nil }
        return Data(buffer)
    }

    @discardableResult
    public static func set(_ value: Data, for key: String, at path: String) -> Bool {
        value.withUnsafeBytes { raw in
            setxattr(path, key, raw.baseAddress, raw.count, 0, XATTR_NOFOLLOW) == 0
        }
    }

    /// The archive's quarantine attribute, if it carries one.
    public static func quarantine(of url: URL) -> Data? {
        value(of: quarantineKey, at: url.path)
    }

    @discardableResult
    public static func applyQuarantine(_ value: Data, to url: URL) -> Bool {
        set(value, for: quarantineKey, at: url.path)
    }
}
