import AppKit
import XCTest
@testable import ZipPorter

/// AppKit dispatches ⌘X/⌘C/⌘V/⌘A and ⌘W to the first responder only when the
/// main menu carries matching key equivalents — a missing Edit menu makes the
/// password fields silently ignore ⌘V, with nothing in the code to point at.
/// These assertions are the only automated guard against that.
@MainActor
final class MainMenuTests: XCTestCase {
    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + items(submenu)
        }
    }

    private func item(_ menu: NSMenu, keyEquivalent: String) -> NSMenuItem? {
        items(menu).first { $0.keyEquivalent == keyEquivalent && !$0.isSeparatorItem }
    }

    func testEditingShortcutsAreBound() throws {
        let menu = MainMenu.build()
        let expected: [(String, Selector)] = [
            ("x", #selector(NSText.cut(_:))),
            ("c", #selector(NSText.copy(_:))),
            ("v", #selector(NSText.paste(_:))),
            ("a", #selector(NSText.selectAll(_:))),
            ("z", Selector(("undo:"))),
            ("Z", Selector(("redo:"))),
        ]
        for (key, action) in expected {
            let found = try XCTUnwrap(item(menu, keyEquivalent: key), "⌘\(key) unbound")
            XCTAssertEqual(found.action, action, "⌘\(key) bound to the wrong action")
            XCTAssertEqual(found.keyEquivalentModifierMask, .command, "⌘\(key) modifiers")
        }
    }

    func testCloseWindowShortcutIsBound() throws {
        let close = try XCTUnwrap(item(MainMenu.build(), keyEquivalent: "w"), "⌘W unbound")
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
    }

    /// The menu bar draws the top-level *item* title; leaving it empty makes
    /// the whole menu invisible even though its submenu is fully populated
    /// (which is exactly how the missing Edit menu got shipped).
    func testTopLevelMenusAreTitledAndLocalized() {
        let titles = MainMenu.build().items.map(\.title)
        for expected in [L("File"), L("Edit"), L("Window")] {
            XCTAssertTrue(titles.contains(expected), "no visible '\(expected)' menu")
        }
    }
}
