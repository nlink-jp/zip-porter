import AppKit

/// The "same folder / ask every time / a fixed folder" chooser, shared by
/// the extraction and creation sections so both sides offer the same
/// choices and behave identically.
@MainActor
final class DestinationPopup: NSObject {
    let popup = NSPopUpButton()

    private let sameFolderTitle: String
    private let onChange: (Preferences.DestinationMode, String?) -> Void
    private var mode: Preferences.DestinationMode = .sameFolder
    private var fixedPath: String?

    init(sameFolderTitle: String,
         onChange: @escaping (Preferences.DestinationMode, String?) -> Void) {
        self.sameFolderTitle = sameFolderTitle
        self.onChange = onChange
        super.init()
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func load(mode: Preferences.DestinationMode, fixedPath: String?) {
        self.mode = mode
        self.fixedPath = fixedPath
        rebuild()
    }

    private func rebuild() {
        popup.removeAllItems()
        if mode == .fixed, let fixedPath {
            popup.addItem(withTitle: FileManager.default.displayName(atPath: fixedPath))
            popup.menu?.addItem(.separator())
        }
        popup.addItem(withTitle: sameFolderTitle)
        popup.addItem(withTitle: L("Ask every time"))
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: L("Choose folder…"))
        switch mode {
        case .fixed: popup.selectItem(at: 0)
        case .sameFolder: popup.selectItem(withTitle: sameFolderTitle)
        case .ask: popup.selectItem(withTitle: L("Ask every time"))
        }
    }

    @objc private func selectionChanged() {
        switch popup.titleOfSelectedItem ?? "" {
        case sameFolderTitle:
            mode = .sameFolder
        case L("Ask every time"):
            mode = .ask
        case L("Choose folder…"):
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                mode = .fixed
                fixedPath = url.path
            }
        default:
            // The remembered folder's own row.
            mode = .fixed
        }
        rebuild()
        onChange(mode, fixedPath)
    }
}
