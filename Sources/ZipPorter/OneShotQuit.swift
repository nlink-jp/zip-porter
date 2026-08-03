import Foundation

/// Whether a Finder-launched ("one-shot") run may end the process yet.
///
/// This exists as a value rather than as `if` statements inside the delegate
/// because the decision is made twice — once when a job finishes, and again
/// when the scheduled quit actually fires, by which time the answer may have
/// changed. Getting the second evaluation wrong is what let a pending quit
/// terminate a live extraction mid-write and a password prompt mid-keystroke.
enum OneShotQuit: Equatable {
    /// Nothing left to announce; leave now.
    case now
    /// A completion banner is still on screen. A foreground notification
    /// dies with its app, so stay this much longer — then decide again.
    case afterBanner(TimeInterval)
    /// The process has a reason to live: the user adopted it, or work is in
    /// flight. Never quit on this answer.
    case stay

    /// - Parameters:
    ///   - isOneShot: the app was started by Finder to handle a file and the
    ///     user has not since claimed it.
    ///   - isBusy: a request is running, queued, or waiting on the user
    ///     (options sheet, password prompt, result dialog).
    ///   - bannerTimeRemaining: seconds the last completion banner still has
    ///     on screen; zero when none was posted.
    static func decide(isOneShot: Bool,
                       isBusy: Bool,
                       bannerTimeRemaining: TimeInterval) -> OneShotQuit {
        // Busy is checked before everything else on purpose: a one-shot
        // session that has been handed new work is no longer idle, and the
        // banner of the *previous* job says nothing about this one.
        guard isOneShot, !isBusy else { return .stay }
        return bannerTimeRemaining > 0 ? .afterBanner(bannerTimeRemaining) : .now
    }
}
