import XCTest
@testable import ZipPorter

/// The rules a Finder-launched run quits by. Each case here is a bug that
/// shipped: a pending quit fired while the *next* archive was extracting
/// (truncated output, silently), while its password prompt was open, and
/// after the user had reclaimed the app from the Dock.
final class OneShotQuitTests: XCTestCase {
    func testIdleOneShotLeavesImmediately() {
        XCTAssertEqual(OneShotQuit.decide(isOneShot: true, isBusy: false), .now)
    }

    /// The truncated-extraction and killed-password-prompt cases: a second
    /// archive arrived while the process was winding down. "Busy" covers
    /// running, queued, and waiting on the user.
    func testBusyNeverQuits() {
        XCTAssertEqual(OneShotQuit.decide(isOneShot: true, isBusy: true), .stay)
    }

    /// The Dock-click case: the user asked for the app, so it stays.
    func testReclaimedAppNeverQuits() {
        for busy in [true, false] {
            XCTAssertEqual(OneShotQuit.decide(isOneShot: false, isBusy: busy), .stay,
                           "isBusy=\(busy)")
        }
    }

    /// Nothing about the answer may depend on when it is asked — there is no
    /// clock in the rule, which is what removed the wind-down window
    /// entirely (ADR-0004).
    func testDecisionIsAFunctionOfItsInputsOnly() {
        XCTAssertEqual(OneShotQuit.decide(isOneShot: true, isBusy: false),
                       OneShotQuit.decide(isOneShot: true, isBusy: false))
    }
}
