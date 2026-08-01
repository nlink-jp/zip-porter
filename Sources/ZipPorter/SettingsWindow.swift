import AppKit

/// Settings window (⌘,) — The Unarchiver-style extraction preferences plus
/// the pack-sheet visibility toggle. Controls write straight to
/// UserDefaults via Preferences.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let destinationPopup = NSPopUpButton()
    private var wrapRadios: [Preferences.WrapMode: NSButton] = [:]
    private var dateRadios: [Preferences.FolderDateMode: NSButton] = [:]
    private let revealCheck = NSButton(checkboxWithTitle: L("Reveal extracted items in Finder"), target: nil, action: nil)
    private let trashCheck = NSButton(checkboxWithTitle: L("Move the archive to the Trash"), target: nil, action: nil)
    private let showOptionsCheck = NSButton(checkboxWithTitle: L("Show Options When Creating a ZIP"), target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        loadState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        loadState()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - UI

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func buildUI() {
        destinationPopup.target = self
        destinationPopup.action = #selector(destinationChanged)

        func radio(_ title: String) -> NSButton {
            NSButton(radioButtonWithTitle: title, target: self, action: #selector(radioChanged))
        }
        wrapRadios = [
            .never: radio(L("Never")),
            .onlyMultiple: radio(L("Only when there are multiple top-level items")),
            .always: radio(L("Always")),
        ]
        dateRadios = [
            .now: radio(L("Current date and time")),
            .archive: radio(L("The archive file's modification date")),
        ]
        for check in [revealCheck, trashCheck, showOptionsCheck] {
            check.target = self
            check.action = #selector(checkboxChanged)
        }

        let destRow = NSStackView(views: [NSTextField(labelWithString: L("Extract to:")), destinationPopup])
        destRow.orientation = .horizontal
        destRow.spacing = 8
        destinationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Radio buttons group by shared superview+action; one stack each.
        let wrapStack = NSStackView(views: [
            wrapRadios[.never]!, wrapRadios[.onlyMultiple]!, wrapRadios[.always]!,
        ])
        let dateStack = NSStackView(views: [dateRadios[.now]!, dateRadios[.archive]!])
        let afterStack = NSStackView(views: [revealCheck, trashCheck])
        for stack in [wrapStack, dateStack, afterStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
        }

        // Each labelled group is one indented block, so the settings read as
        // discrete choices rather than one long ladder of controls.
        func group(_ title: String, _ content: NSView) -> NSStackView {
            let indented = NSStackView(views: [content])
            indented.orientation = .vertical
            indented.alignment = .leading
            indented.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
            let group = NSStackView(views: [NSTextField(labelWithString: title), indented])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            return group
        }

        let extraction = NSStackView(views: [
            destRow,
            group(L("Create a new folder for extracted files:"), wrapStack),
            group(L("Created folder's modification date:"), dateStack),
            group(L("After extracting:"), afterStack),
        ])
        let creating = NSStackView(views: [showOptionsCheck])
        for stack in [extraction, creating] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
        }

        let stack = NSStackView(views: [
            sectionLabel(L("Extraction")),
            extraction,
            NSBox.separator(),
            sectionLabel(L("Creating")),
            creating,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A bare NSStackView as contentView gets sized to its own fitting
        // width and clips anything wider (the destination popup). Pinning it
        // inside a container with an explicit width is what actually holds
        // the window open at a comfortable size.
        let container = NSView()
        container.addSubview(stack)
        let width = container.widthAnchor.constraint(equalToConstant: 480)
        width.priority = .required
        NSLayoutConstraint.activate([
            width,
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28),
        ])
        window?.contentView = container
        window?.setContentSize(container.fittingSize)
    }

    private func rebuildDestinationItems(_ prefs: Preferences) {
        destinationPopup.removeAllItems()
        if prefs.destinationMode == .fixed, let path = prefs.fixedDestinationPath {
            destinationPopup.addItem(withTitle: FileManager.default.displayName(atPath: path))
            destinationPopup.menu?.addItem(.separator())
        }
        destinationPopup.addItem(withTitle: L("Same folder as the archive"))
        destinationPopup.addItem(withTitle: L("Ask every time"))
        destinationPopup.menu?.addItem(.separator())
        destinationPopup.addItem(withTitle: L("Choose folder…"))
        switch prefs.destinationMode {
        case .fixed: destinationPopup.selectItem(at: 0)
        case .sameFolder:
            destinationPopup.selectItem(withTitle: L("Same folder as the archive"))
        case .ask:
            destinationPopup.selectItem(withTitle: L("Ask every time"))
        }
    }

    private func loadState() {
        let prefs = Preferences.load()
        rebuildDestinationItems(prefs)
        for (mode, button) in wrapRadios { button.state = prefs.wrapMode == mode ? .on : .off }
        for (mode, button) in dateRadios { button.state = prefs.folderDate == mode ? .on : .off }
        revealCheck.state = prefs.revealInFinder ? .on : .off
        trashCheck.state = prefs.trashArchiveAfterExtract ? .on : .off
        showOptionsCheck.state = prefs.skipOptions ? .off : .on
    }

    // MARK: - Actions

    @objc private func destinationChanged() {
        var prefs = Preferences.load()
        let title = destinationPopup.titleOfSelectedItem ?? ""
        switch title {
        case L("Same folder as the archive"):
            prefs.destinationMode = .sameFolder
        case L("Ask every time"):
            prefs.destinationMode = .ask
        case L("Choose folder…"):
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                prefs.destinationMode = .fixed
                prefs.fixedDestinationPath = url.path
            }
        default:
            prefs.destinationMode = .fixed
        }
        prefs.save()
        rebuildDestinationItems(prefs)
    }

    @objc private func radioChanged(_ sender: NSButton) {
        var prefs = Preferences.load()
        for (mode, button) in wrapRadios where button === sender { prefs.wrapMode = mode }
        for (mode, button) in dateRadios where button === sender { prefs.folderDate = mode }
        prefs.save()
        loadState()
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        var prefs = Preferences.load()
        switch sender {
        case revealCheck: prefs.revealInFinder = sender.state == .on
        case trashCheck: prefs.trashArchiveAfterExtract = sender.state == .on
        case showOptionsCheck: prefs.skipOptions = sender.state == .off
        default: break
        }
        prefs.save()
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
