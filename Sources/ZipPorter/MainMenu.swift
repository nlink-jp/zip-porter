import AppKit

/// Main menu: app menu (About / Settings / Hide / Quit), File, Edit and
/// Window.
///
/// The Edit menu is not decoration: AppKit routes ⌘X/⌘C/⌘V/⌘A to the first
/// responder *through* main-menu key equivalents. Without these items the
/// password fields silently ignore ⌘V. The same holds for ⌘W and
/// `performClose:`.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: L("About ZipPorter"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Settings…"),
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Hide ZipPorter"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Quit ZipPorter"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // The menu bar draws the *item's* title, not the submenu's — an
        // untitled item is an invisible menu. (The app and Window menus get
        // away with it only because AppKit special-cases them.)
        let fileItem = NSMenuItem(title: L("File"), action: nil, keyEquivalent: "")
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: L("File"))
        fileItem.submenu = fileMenu
        // Closing the droplet window ends the session (see
        // applicationShouldTerminateAfterLastWindowClosed) — ⌘W is simply the
        // keyboard route to the red button, not a separate behaviour.
        fileMenu.addItem(
            withTitle: L("Close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")

        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        main.addItem(editItem)
        let editMenu = NSMenu(title: L("Edit"))
        editItem.submenu = editMenu
        // undo:/redo: live on the field editor's undo manager, not on a class
        // we can name — hence the string selectors.
        editMenu.addItem(
            withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(
            withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: L("Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")

        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("Window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: L("Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")

        return main
    }

    /// Builds the menu and wires it to the running application. Kept separate
    /// from `build()` so the menu can be inspected in tests, where there is no
    /// `NSApp`.
    static func install(into app: NSApplication) {
        let main = build()
        app.mainMenu = main
        app.windowsMenu = main.items.compactMap(\.submenu)
            .first { $0.title == L("Window") }
    }
}
