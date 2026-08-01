import Darwin
import Foundation

/// Interactive password entry on /dev/tty with echo disabled. Passwords
/// never travel through argv (shell history) — this prompt is the only way
/// the CLI accepts one.
enum PasswordPrompt {
    static func read(_ prompt: String) -> String? {
        guard let tty = fopen("/dev/tty", "r+") else { return nil }
        defer { fclose(tty) }
        let fd = fileno(tty)

        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fd, TCSAFLUSH, &raw)
        defer { tcsetattr(fd, TCSAFLUSH, &original) }

        fputs(prompt, tty)
        fflush(tty)
        var bytes: [UInt8] = []
        while true {
            let c = fgetc(tty)
            if c == EOF || c == 0x0A { break }
            bytes.append(UInt8(truncatingIfNeeded: c))
        }
        fputs("\n", tty)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Prompt twice for a new password (pack); returns nil on mismatch or
    /// missing tty.
    static func readNew() -> String? {
        guard let first = read("Password: ") else { return nil }
        guard let second = read("Verify password: ") else { return nil }
        guard first == second, !first.isEmpty else { return nil }
        return first
    }
}
