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
        case .pack, .unpack, .inspect:
            FileHandle.standardError.write(Data(
                "zip-porter: this command is not implemented yet (engine phase in progress)\n".utf8))
            exit(64)
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
        app.mainMenu = MainMenu.build()
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = makeMainWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Scaffold window: drop zone arrives in the GUI phase. The version is
    /// always visible in the UI (org rule: GUI must show its version).
    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "ZipPorter"
        window.center()

        let label = NSTextField(labelWithString: "zip-porter \(AppInfo.version)")
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        return window
    }
}
