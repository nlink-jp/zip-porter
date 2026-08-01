import AppKit

enum AppInfo {
    /// The app's short version (from Info.plist), with any leading "v" stripped.
    /// Falls back to "dev" when run without a bundle (e.g. `swift run`).
    static var version: String {
        normalize((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The menu must exist before launch finishes so Finder-open events
        // land in a fully wired app.
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        mainViewController.handle(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }
}
