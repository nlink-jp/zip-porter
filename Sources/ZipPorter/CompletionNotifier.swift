import Foundation
import UserNotifications

/// Posts the "done" signal as a Notification Center banner, so a clean
/// completion needs no OK button. Falls back to doing nothing when the
/// user declined notification permission — with reveal-in-Finder on, the
/// Finder window itself is the completion signal.
@MainActor
final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifier()
    private var available = false

    /// Call once an operation starts, so authorization is settled by the
    /// time the completion fires. Safe to call repeatedly.
    func prepare() {
        // UNUserNotificationCenter traps in unbundled processes (swift run).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.available = granted }
        }
    }

    /// Post the completion banner, then run `completion` once the request
    /// has been handed to the system (so a one-shot launch can quit without
    /// losing the notification).
    func notify(title: String, body: String, completion: @escaping @MainActor () -> Void) {
        guard available, Bundle.main.bundleIdentifier != nil else {
            completion()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    /// Banners must show even while the app is frontmost — the droplet
    /// window is usually the active app when the operation finishes.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
