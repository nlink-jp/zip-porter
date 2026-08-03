import AppKit

enum AppInfo {
    /// The app's short version (from Info.plist), with any leading "v"
    /// stripped. Falls back to "dev" only when there is genuinely no bundle
    /// (e.g. `swift run`).
    static var version: String {
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !value.isEmpty {
            return normalize(value)
        }
        // Launched through the Homebrew cask's symlink in bin/, Bundle.main
        // is not the .app — read Info.plist relative to the real executable
        // (…/Contents/MacOS/ZipPorter → …/Contents/Info.plist).
        if let plist = infoPlistBesideExecutable(),
           let value = plist["CFBundleShortVersionString"] as? String {
            return normalize(value)
        }
        return "dev"
    }

    private static func infoPlistBesideExecutable() -> NSDictionary? {
        let candidates = [
            Bundle.main.executableURL,
            URL(fileURLWithPath: CommandLine.arguments.first ?? ""),
        ].compactMap { $0?.resolvingSymlinksInPath() }
        for executable in candidates {
            let plist = executable
                .deletingLastPathComponent()   // MacOS/
                .deletingLastPathComponent()   // Contents/
                .appendingPathComponent("Info.plist")
            if let dict = NSDictionary(contentsOf: plist) { return dict }
        }
        return nil
    }

    static func normalize(_ raw: String) -> String {
        raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
    }
}

@main
@MainActor
enum ZipPorterMain {
    /// `NSApplication.delegate` is a weak reference — the delegate must be owned here.
    private static var delegate: AppDelegate?

    static func main() {
        switch CLI.parse(CommandLine.arguments) {
        case .version:
            // `brew test` and release verification call `zip-porter --version`;
            // answer on stdout and exit before any AppKit machinery starts.
            print("zip-porter \(AppInfo.version)")
            exit(0)
        case .pack(let args):
            CLIRun.pack(args)
        case .unpack(let args):
            CLIRun.unpack(args)
        case .inspect(let args):
            CLIRun.inspect(args)
        case .unknown(let word):
            FileHandle.standardError.write(Data(
                "zip-porter: unknown command '\(word)'\n\(CLI.usage)\n".utf8))
            exit(64)
        case .gui:
            runGUI()
        }
    }

    private static func runGUI() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let mainViewController = MainViewController()
    /// True once launch is complete; open events that arrive before this
    /// are the reason the app started (LaunchServices delivers them between
    /// willFinishLaunching and didFinishLaunching).
    private var didFinishLaunching = false
    /// The app was started by Finder to handle a file and has done nothing
    /// else since — it should go away when that work is done rather than
    /// linger as an empty window the user never asked for.
    private var isOneShotLaunch = false
    /// Open events that arrived before the window existed; the operation
    /// sheet needs a parent window, so they wait for it.
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The menu must exist before launch finishes so Finder-open events
        // land in a fully wired app.
        MainMenu.install(into: NSApp)
        CompletionNotifier.shared.prepare()
        mainViewController.workDidFinish = { [weak self] in
            guard let self, self.isOneShotLaunch else { return }
            // A foreground notification lives only as long as its app, so
            // quitting straight away cuts the banner short. Wait out just
            // the banner's remaining time — and nothing at all when no
            // banner was shown (the result went to a dialog the user has
            // already dismissed, or notifications are off).
            let wait = CompletionNotifier.shared.remainingBannerTime()
            guard wait > 0 else {
                NSApp.terminate(nil)
                return
            }
            // Leave the Dock immediately so nothing lingers visually.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                NSApp.terminate(nil)
            }
        }
        mainViewController.userDidInteract = { [weak self] in
            self?.isOneShotLaunch = false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        let queued = pendingURLs
        pendingURLs = []

        // Launched by Finder to handle one archive: the droplet window would
        // be noise for a job the user already described by double-clicking.
        // Only the status dialog appears, and the app leaves when it is done.
        if queued.isEmpty {
            showDropWindow()
        } else {
            NSApp.activate()
            mainViewController.handle(queued)
        }
    }

    private func showDropWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "ZipPorter"
        window.contentViewController = mainViewController
        window.setContentSize(NSSize(width: 460, height: 320))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Finder integration: double-clicked .zip files (LSHandlerRank Default)
    /// and items dropped on the Dock icon arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            isOneShotLaunch = true
            pendingURLs.append(contentsOf: urls)
            return
        }
        mainViewController.handle(urls)
    }

    /// Clicking the Dock icon of a still-running one-shot launch is the user
    /// asking for the app itself — give them the droplet window and stop
    /// treating the session as disposable.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            isOneShotLaunch = false
            showDropWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A one-shot run ends when its work does, not when a dialog closes —
        // quitting on window count would cut off the reveal-in-Finder step.
        !isOneShotLaunch
    }

    @objc func showSettings(_ sender: Any?) {
        isOneShotLaunch = false
        SettingsWindowController.shared.show()
    }
}
