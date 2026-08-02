import Darwin

/// Permission bits for extracted items.
///
/// A ZIP's Unix mode field is attacker-controlled, so it decides at most
/// what the user's umask already allows — the rule `unzip` and `ditto`
/// follow. Copying the archive's bits verbatim drops group- and
/// world-writable files into the user's folders, which on a shared Mac
/// means another local account can rewrite them.
public enum PosixPermissions {
    /// The process umask, read once.
    ///
    /// Darwin has no `getumask(2)`: the only way to read the value is to
    /// set it and put it back. Doing that once behind a lazy static keeps
    /// the window in which another thread could create a file under the
    /// wrong mask down to a single pair of syscalls — and the temporary
    /// value is 022 rather than 0, so even a file created inside that
    /// window is no worse off than the common default.
    public static let umask: UInt16 = {
        let current = Darwin.umask(0o022)
        Darwin.umask(current)
        return UInt16(current)
    }()

    /// What to chmod an extracted item to: the archive's request, minus
    /// what the umask forbids, plus the owner bits we always keep so the
    /// extraction can finish and the user can reach the result.
    ///
    /// Only the low nine bits are read, so setuid/setgid/sticky never
    /// survive extraction.
    public static func extracted(mode: UInt16,
                                 isDirectory: Bool,
                                 umask: UInt16 = PosixPermissions.umask) -> UInt16 {
        (mode & 0o777 & ~umask) | (isDirectory ? 0o700 : 0o600)
    }
}
