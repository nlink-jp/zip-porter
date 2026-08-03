import Foundation

/// Whether a Finder-launched ("one-shot") run may end the process yet.
///
/// This exists as a value rather than as `if` statements inside the delegate
/// so the rule is stated once and can be tested. Every case here is a bug
/// that shipped: a quit that landed on the *next* archive's extraction
/// (truncated output, no error), on its password prompt, and on a window the
/// user had just reclaimed from the Dock.
///
/// There is deliberately no "wait a moment first" answer any more. Until
/// ADR-016 the app stayed alive after posting its completion banner, because
/// an immediately-presented notification is withdrawn when its app exits —
/// and that gap, visibly gone but still accepting open events, is what those
/// bugs lived in. Notifications are now scheduled rather than presented by
/// the app, so a finished run has nothing left to wait for.
enum OneShotQuit: Equatable {
    /// Nothing left to do; leave now.
    case now
    /// The process has a reason to live: the user adopted it, or work is in
    /// flight. Never quit on this answer.
    case stay

    /// - Parameters:
    ///   - isOneShot: the app was started by Finder to handle files and the
    ///     user has not since claimed it.
    ///   - isBusy: a request is running, queued, or waiting on the user
    ///     (options sheet, password prompt, result dialog).
    static func decide(isOneShot: Bool, isBusy: Bool) -> OneShotQuit {
        isOneShot && !isBusy ? .now : .stay
    }
}
