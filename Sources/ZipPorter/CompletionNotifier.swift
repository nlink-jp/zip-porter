import AppKit
import Foundation
import UserNotifications

/// Posts the "done" signal as a Notification Center banner, so a clean
/// completion needs no OK button. Falls back to doing nothing when the
/// user declined notification permission — with reveal-in-Finder on, the
/// Finder window itself is the completion signal.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    /// Called when the user clicks a completion banner. The delegate uses it
    /// to bring the app back into a sensible state.
    var didOpenNotification: (() -> Void)?

    /// The notification is *scheduled* a hair in the future rather than
    /// delivered immediately (ADR-016). A notification presented through
    /// `willPresent` belongs to the app that posted it and is withdrawn when
    /// that app exits — measured: a one-shot run that quit at presentation
    /// left no banner on screen at all, which is why the app used to demote
    /// itself to `.accessory` and linger for seconds. With a trigger,
    /// presentation belongs to notificationd: the banner appears and lives
    /// its full life with the process already gone, so nothing has to keep a
    /// finished app alive to babysit it.
    private nonisolated static let scheduleDelay: TimeInterval = 0.1

    /// Paths to select in Finder if the user clicks the banner.
    private nonisolated static let revealKey = "reveal"

    /// Wire the delegate early — foreground banners depend on it. Safe to
    /// call repeatedly.
    func prepare() {
        // UNUserNotificationCenter traps in unbundled processes (swift run).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post the completion banner, then run `completion`.
    ///
    /// Authorization is resolved HERE, inside the chain — not from a cached
    /// flag, which races short operations and silently skips their banner.
    /// `completion` runs once the notification has been accepted, which is
    /// all the caller has to wait for: presentation is no longer its
    /// business.
    func notify(title: String, body: String, reveal: [URL],
                completion: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let revealPaths = reveal.map(\.path)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Self.revealKey: revealPaths]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: Self.scheduleDelay, repeats: false))
            // Ask for the centre again rather than capturing the one from
            // the main actor: `current()` is a singleton, so this is the
            // same object, but nothing non-Sendable crosses into this
            // background callback to be taken on trust.
            UNUserNotificationCenter.current().add(request) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
            }
        }
    }

    /// Banners must show even while the app is frontmost — the droplet
    /// window is usually the active app when the operation finishes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// Clicking the banner asks for the result, not for the app: show what
    /// was produced in Finder. By now the run that posted it has usually
    /// exited, so this often arrives in a process the click just launched.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content
            .userInfo[Self.revealKey] as? [String] ?? []
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                if !urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                CompletionNotifier.shared.didOpenNotification?()
            }
            completionHandler()
        }
    }
}
