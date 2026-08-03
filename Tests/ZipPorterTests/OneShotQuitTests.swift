import XCTest
@testable import ZipPorter

/// The rules a Finder-launched run quits by. Each case here is a bug that
/// shipped: a pending quit fired while the *next* archive was extracting
/// (truncated output, silently), while its password prompt was open, and
/// after the user had reclaimed the app from the Dock.
final class OneShotQuitTests: XCTestCase {
    func testIdleOneShotWithNoBannerLeavesImmediately() {
        XCTAssertEqual(
            OneShotQuit.decide(isOneShot: true, isBusy: false, bannerTimeRemaining: 0),
            .now)
    }

    func testIdleOneShotWaitsOutItsBanner() {
        XCTAssertEqual(
            OneShotQuit.decide(isOneShot: true, isBusy: false, bannerTimeRemaining: 3.2),
            .afterBanner(3.2))
    }

    /// The truncated-extraction and killed-password-prompt cases: a second
    /// archive arrived while the process was winding down.
    func testBusyNeverQuits() {
        XCTAssertEqual(
            OneShotQuit.decide(isOneShot: true, isBusy: true, bannerTimeRemaining: 0),
            .stay)
    }

    /// Busy outranks a finished banner — the banner belongs to the previous
    /// job and says nothing about the one now running.
    func testBusyOutranksAnExpiredBanner() {
        XCTAssertEqual(
            OneShotQuit.decide(isOneShot: true, isBusy: true, bannerTimeRemaining: 2.0),
            .stay)
    }

    /// The Dock-click case: the user asked for the app, so it stays even
    /// though the previous run had already scheduled its exit.
    func testReclaimedAppNeverQuits() {
        for busy in [true, false] {
            for banner in [0.0, 2.5] {
                XCTAssertEqual(
                    OneShotQuit.decide(isOneShot: false, isBusy: busy,
                                       bannerTimeRemaining: banner),
                    .stay,
                    "isBusy=\(busy) banner=\(banner)")
            }
        }
    }

    /// The decision is re-evaluated when the timer fires, so it must be a
    /// pure function of the state passed in — never of when it is called.
    func testDecisionIsAFunctionOfItsInputsOnly() {
        let first = OneShotQuit.decide(isOneShot: true, isBusy: false, bannerTimeRemaining: 1.0)
        let second = OneShotQuit.decide(isOneShot: true, isBusy: false, bannerTimeRemaining: 1.0)
        XCTAssertEqual(first, second)
    }
}
