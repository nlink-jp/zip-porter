import Foundation
import UserNotifications

/// Posts the "done" signal as a Notification Center banner, so a clean
/// completion needs no OK button. Falls back to doing nothing when the
/// user declined notification permission — with reveal-in-Finder on, the
/// Finder window itself is the completion signal.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()

    /// Wire the delegate early (banners while frontmost need it). Safe to
    /// call repeatedly.
    func prepare() {
        // UNUserNotificationCenter traps in unbundled processes (swift run).
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Post the completion banner, then run `completion`.
    ///
    /// Authorization is resolved HERE, inside the chain — not from a cached
    /// flag. A cached flag races the operation: a fast extraction finished
    /// before the async authorization callback landed, so the banner was
    /// skipped, and the one-shot quit then tore down the first-run
    /// permission prompt before the user could answer it. Resolving in the
    /// chain means a first run waits for the prompt's answer, and every
    /// later run gets the settled state immediately.
    func notify(title: String, body: String, completion: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
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
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in
                // Give the banner a beat to materialize before a one-shot
                // launch terminates the app; it survives the quit once shown.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
}
