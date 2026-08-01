import Foundation
import UserNotifications

/// Posts the "done" signal as a Notification Center banner, so a clean
/// completion needs no OK button. Falls back to doing nothing when the
/// user declined notification permission — with reveal-in-Finder on, the
/// Finder window itself is the completion signal.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    /// Runs once the banner is actually on screen (or the wait times out),
    /// so a one-shot launch does not terminate mid-presentation.
    private var pendingCompletion: (@MainActor () -> Void)?

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
    /// The completion is then deferred until the system actually presents
    /// the notification: terminating the app before that point cancels the
    /// banner the user was supposed to see.
    func notify(title: String, body: String, completion: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else {
                            completion()
                            return
                        }
                        self.pendingCompletion = completion
                        // Presentation is asynchronous and not guaranteed
                        // (Focus modes swallow banners), so never leave the
                        // app waiting on it forever.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self.runPendingCompletion()
                        }
                    }
                }
            }
        }
    }

    private func runPendingCompletion() {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        completion()
    }

    /// Banners must show even while the app is frontmost — the droplet
    /// window is usually the active app when the operation finishes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
        // The banner is on screen now; let it settle before the caller's
        // completion (which may quit the app) runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                CompletionNotifier.shared.runPendingCompletion()
            }
        }
    }
}
