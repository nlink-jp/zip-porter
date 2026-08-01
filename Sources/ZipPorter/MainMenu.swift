import AppKit

/// Main menu: app menu (About / Settings / Hide / Quit) and Window.
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

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L("Window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: L("Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return main
    }
}
