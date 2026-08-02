import AppKit
import ZipPorterCore


/// Coalesces high-frequency byte progress onto the main thread: a UI
/// update fires only when the fraction moved visibly.
private final class ProgressForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastPath = ""
    private let apply: @MainActor (Double, String?) -> Void

    init(apply: @escaping @MainActor (Double, String?) -> Void) {
        self.apply = apply
    }

    func forward(_ progress: OperationProgress) {
        lock.lock()
        let pathChanged = !progress.currentPath.isEmpty && progress.currentPath != lastPath
        let fractionMoved = progress.fraction - lastFraction >= 0.005 || progress.fraction >= 1
        guard pathChanged || fractionMoved else {
            lock.unlock()
            return
        }
        lastFraction = progress.fraction
        if pathChanged { lastPath = progress.currentPath }
        let path = pathChanged ? progress.currentPath : nil
        let fraction = progress.fraction
        lock.unlock()
        DispatchQueue.main.async { [apply] in
            MainActor.assumeIsolated { apply(fraction, path) }
        }
    }
}

/// The drop window's content and the pack/unpack flows.
@MainActor
final class MainViewController: NSViewController, DropViewDelegate {
    /// Called when the last queued operation finishes and its result sheet
    /// is dismissed — the delegate uses this to quit a Finder-launched run.
    var workDidFinish: (() -> Void)?
    /// Called when the user drives the app themselves (a drop, or opening
    /// settings), which means it is no longer a one-shot Finder launch.
    var userDidInteract: (() -> Void)?

    private let dropView = DropView()
    private var busy = false {
        didSet {
            if !busy { workDidFinish?() }
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
        dropView.delegate = self
        dropView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dropView)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: L("Drop files or folders to create a ZIP"))
        title.font = .systemFont(ofSize: 15, weight: .medium)
        let subtitle = NSTextField(labelWithString: L("Drop a ZIP here to extract it"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let hints = NSStackView(views: [icon, title, subtitle])
        hints.orientation = .vertical
        hints.alignment = .centerX
        hints.spacing = 8
        hints.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(hints)

        // Org rule: the GUI always shows its version.
        let version = NSTextField(labelWithString: "zip-porter \(AppInfo.version)")
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .tertiaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(version)

        // Settings are otherwise only reachable through the menu bar (⌘,) —
        // easy to miss in a one-window drop app.
        let settingsButton = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("Settings"))
                ?? NSImage(),
            target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .accessoryBarAction
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = L("Settings")
        // Nothing else in the window takes focus, so the button would come
        // up wearing a focus ring on launch.
        settingsButton.focusRingType = .none
        settingsButton.refusesFirstResponder = true
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            dropView.topAnchor.constraint(equalTo: root.topAnchor),
            dropView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dropView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            hints.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            hints.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
            version.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            version.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            settingsButton.centerYAnchor.constraint(equalTo: version.centerYAnchor),
        ])
        view = root
    }

    @objc private func openSettings() {
        userDidInteract?()
        SettingsWindowController.shared.show()
    }

    /// nil on the Finder-launch path: no droplet window is created there,
    /// and asking for `view` would build one. Dialogs stand alone instead.
    private var hostWindow: NSWindow? { isViewLoaded ? view.window : nil }

    // MARK: - Entry points

    func dropView(_ view: DropView, didReceive urls: [URL]) {
        userDidInteract?()
        handle(urls)
    }

    /// Shared entry for drops and Finder-open events. All-ZIP drops extract;
    /// anything else packs (a mixed drop stores the ZIPs as plain files).
    func handle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !busy else {
            NSSound.beep()
            return
        }
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if zips.count == urls.count {
            startUnpackQueue(zips)
        } else {
            startPack(urls)
        }
    }

    private func showError(_ headline: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Pack flow

    private func startPack(_ urls: [URL]) {
        busy = true
        CompletionNotifier.shared.prepare()
        let prefs = Preferences.load()
        if prefs.skipOptions && !prefs.usePassword {
            runPack(urls, cp932: prefs.cp932, zipCrypto: false, password: nil)
            return
        }
        PackOptionsSheet(prefs: prefs).present(on: hostWindow) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.busy = false
                return
            }
            var newPrefs = Preferences.load()
            newPrefs.usePassword = result.password != nil
            newPrefs.cp932 = result.cp932
            newPrefs.zipCrypto = result.zipCrypto
            newPrefs.skipOptions = result.skipNext
            newPrefs.save()
            self.runPack(urls, cp932: result.cp932, zipCrypto: result.zipCrypto,
                         password: result.password)
        }
    }

    /// Where the new archive goes, mirroring the extraction destination
    /// setting: next to the originals, into a fixed folder, or wherever the
    /// user says in a save panel. `overwrite` is true only for that last
    /// case, where the panel already asked about replacing a file.
    private func resolvePackOutput(for inputs: [URL],
                                   completion: @escaping (_ output: URL?, _ overwrite: Bool) -> Void) {
        let prefs = Preferences.load()
        let suggested = defaultPackOutput(for: inputs)
        switch prefs.packDestinationMode {
        case .sameFolder:
            completion(suggested, false)
        case .fixed:
            guard let path = prefs.packFixedDestinationPath else {
                completion(suggested, false)
                return
            }
            completion(URL(fileURLWithPath: path)
                .appendingPathComponent(suggested.lastPathComponent), false)
        case .ask:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested.lastPathComponent
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.canCreateDirectories = true
            if #available(macOS 11.0, *) { panel.allowedContentTypes = [.zip] }
            guard let hostWindow else {
                let response = panel.runModal()
                completion(response == .OK ? panel.url : nil, true)
                return
            }
            panel.beginSheetModal(for: hostWindow) { response in
                completion(response == .OK ? panel.url : nil, true)
            }
        }
    }

    private func defaultPackOutput(for inputs: [URL]) -> URL {
        if inputs.count == 1 {
            let single = inputs[0]
            return single.deletingLastPathComponent()
                .appendingPathComponent(single.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("zip")
        }
        return inputs[0].deletingLastPathComponent()
            .appendingPathComponent(L("Archive"))
            .appendingPathExtension("zip")
    }

    private func runPack(_ urls: [URL], cp932: Bool, zipCrypto: Bool, password: String?) {
        resolvePackOutput(for: urls) { [weak self] output, overwrite in
            guard let self else { return }
            guard let output else {
                self.busy = false
                return
            }
            self.runPack(urls, output: output, overwrite: overwrite,
                         cp932: cp932, zipCrypto: zipCrypto, password: password)
        }
    }

    private func runPack(_ urls: [URL], output: URL, overwrite: Bool,
                         cp932: Bool, zipCrypto: Bool, password: String?) {
        var options = Packer.Options()
        options.nameEncoding = cp932 ? .cp932 : .utf8
        options.overwrite = overwrite
        if let password {
            options.encryption = zipCrypto ? .zipCrypto(password: password) : .aes256(password: password)
        }
        let sheet = OperationSheet(title: L("Packing…"))
        sheet.begin(on: hostWindow)
        let flag = sheet.flag
        let forwarder = ProgressForwarder { fraction, path in
            sheet.setFraction(fraction)
            if let path { sheet.update(path) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Packer.pack(
                    inputs: urls, output: output, options: options,
                    progress: { forwarder.forward($0) },
                    shouldCancel: { flag.isCancelled })
                DispatchQueue.main.async {
                    // Excluding macOS metadata is what this app is FOR —
                    // routine, not a warning — so it rides along in the
                    // completion line rather than forcing a dialog. Skipped
                    // symlinks are a real deviation and still do.
                    var notes: [String] = []
                    if !result.skippedSymlinks.isEmpty {
                        notes.append(L("Skipped symbolic links:")
                            + " \(result.skippedSymlinks.count)")
                    }
                    var summary = result.outputURL.lastPathComponent + "\n"
                        + Self.itemCount(files: result.fileCount,
                                         directories: result.directoryCount)
                    if !result.skippedJunk.isEmpty {
                        summary += "\n" + L("Excluded macOS metadata files:")
                            + " \(result.skippedJunk.count)"
                    }
                    let done: @MainActor () -> Void = {
                        if Preferences.load().revealCreatedArchive {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        }
                        self.busy = false
                    }
                    if notes.isEmpty {
                        self.announceCompletion(sheet: sheet,
                                                title: L("Archive created"),
                                                summary: summary, done: done)
                    } else {
                        sheet.finish(title: L("Archive created"),
                                     summary: summary, notes: notes, completion: done)
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    sheet.dismiss()
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    sheet.dismiss()
                    self.showError(L("Could not create the archive."), Self.describe(error))
                    self.busy = false
                }
            }
        }
    }


    /// Announce a clean finish the way the user asked for: a banner, the
    /// result dialog, or nothing at all. Runs `done` when the user is
    /// through with it. Anything with notes never reaches here — those
    /// always get the dialog (ADR-012).
    private func announceCompletion(sheet: OperationSheet,
                                    title: String,
                                    summary: String,
                                    done: @escaping @MainActor () -> Void) {
        switch Preferences.load().completionStyle {
        case .notification:
            sheet.dismiss()
            CompletionNotifier.shared.notify(
                title: title,
                body: summary.replacingOccurrences(of: "\n", with: " — "),
                completion: done)
        case .dialog:
            sheet.finish(title: title, summary: summary, notes: [], completion: done)
        case .silent:
            sheet.dismiss()
            done()
        }
    }

    private static func itemCount(files: Int, directories: Int) -> String {
        String(format: L("%1$d files, %2$d folders"), files, directories)
    }

    // MARK: - Unpack flow

    private func startUnpackQueue(_ zips: [URL]) {
        busy = true
        CompletionNotifier.shared.prepare()
        var queue = zips
        func next() {
            guard let zip = queue.first else {
                busy = false
                return
            }
            queue.removeFirst()
            unpackOne(zip) { next() }
        }
        next()
    }

    private func resolveDestination(_ prefs: Preferences,
                                    completion: @escaping (URL?, _ cancelled: Bool) -> Void) {
        switch prefs.destinationMode {
        case .sameFolder:
            completion(nil, false)
        case .fixed:
            completion(prefs.fixedDestinationPath.map { URL(fileURLWithPath: $0) }, false)
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = L("Extract")
            guard let hostWindow else {
                let response = panel.runModal()
                completion(response == .OK ? panel.url : nil, response != .OK)
                return
            }
            panel.beginSheetModal(for: hostWindow) { response in
                if response == .OK, let url = panel.url {
                    completion(url, false)
                } else {
                    completion(nil, true)
                }
            }
        }
    }

    private func unpackOne(_ zip: URL, password: String? = nil,
                           destination: URL? = nil, destinationResolved: Bool = false,
                           completion: @escaping () -> Void) {
        let prefs = Preferences.load()
        if !destinationResolved {
            resolveDestination(prefs) { [weak self] dest, cancelled in
                guard let self else { return }
                if cancelled {
                    completion()
                    return
                }
                self.unpackOne(zip, password: password, destination: dest,
                               destinationResolved: true, completion: completion)
            }
            return
        }

        var options = Unpacker.Options()
        options.destination = destination
        options.password = password
        options.folderPolicy = prefs.wrapMode.folderPolicy
        let sheet = OperationSheet(title: L("Extracting…"))
        sheet.begin(on: hostWindow)
        let flag = sheet.flag
        let forwarder = ProgressForwarder { fraction, path in
            sheet.setFraction(fraction)
            if let path { sheet.update(path) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Unpacker.unpack(
                    zipURL: zip, options: options,
                    progress: { forwarder.forward($0) },
                    shouldCancel: { flag.isCancelled })
                DispatchQueue.main.async {
                    let summary = result.root.lastPathComponent + "\n"
                        + Self.itemCount(files: result.extractedFiles,
                                         directories: result.extractedDirectories)
                    let notes = Self.extractionNotes(result)
                    let done: @MainActor () -> Void = {
                        self.finishUnpack(zip: zip, result: result, prefs: prefs)
                        completion()
                    }
                    if notes.isEmpty {
                        self.announceCompletion(sheet: sheet,
                                                title: L("Archive extracted"),
                                                summary: summary, done: done)
                    } else {
                        sheet.finish(title: L("Archive extracted"),
                                     summary: summary, notes: notes, completion: done)
                    }
                }
            } catch let error as ZipReaderError where Self.isPasswordProblem(error) {
                DispatchQueue.main.async {
                    sheet.dismiss()
                    let hint = error == .passwordRequired
                        ? L("This archive is encrypted.")
                        : L("Wrong password. Try again.")
                    PasswordSheet(message: "\(zip.lastPathComponent) — \(hint)")
                        .present(on: self.hostWindow) { entered in
                            guard let entered, !entered.isEmpty else {
                                completion()
                                return
                            }
                            self.unpackOne(zip, password: entered, destination: destination,
                                           destinationResolved: true, completion: completion)
                        }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    sheet.dismiss()
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    sheet.dismiss()
                    self.showError(L("Could not extract the archive."), Self.describe(error))
                    completion()
                }
            }
        }
    }

    private static func isPasswordProblem(_ error: ZipReaderError) -> Bool {
        switch error {
        case .passwordRequired, .wrongPassword, .authenticationFailed:
            return true
        default:
            return false
        }
    }

    /// Security-relevant outcomes must not be silent in the GUI the way a
    /// CLI warning line can be: unsafe paths were dropped, or entries were
    /// renamed to avoid overwriting each other. These ride along in the
    /// result sheet rather than in a second alert.
    private static func extractionNotes(_ result: Unpacker.Result) -> [String] {
        var lines: [String] = []
        if !result.skippedUnsafe.isEmpty {
            lines.append(L("Skipped entries with unsafe paths:") + "\n"
                + result.skippedUnsafe.prefix(6).map { "  \($0)" }.joined(separator: "\n"))
        }
        if !result.skippedSymlinks.isEmpty {
            lines.append(L("Skipped symbolic links:") + " \(result.skippedSymlinks.count)")
        }
        if !result.renamedDuplicates.isEmpty {
            lines.append(L("Duplicate names were extracted under new names:") + "\n"
                + result.renamedDuplicates.prefix(6)
                    .map { "  \($0.original) → \($0.chosen)" }.joined(separator: "\n"))
        }
        return lines
    }

    private func finishUnpack(zip: URL, result: Unpacker.Result, prefs: Preferences) {
        if prefs.folderDate == .archive, result.createdWrapper,
           let mtime = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.modificationDate] as? Date {
            try? FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: result.root.path)
        }
        if prefs.trashArchiveAfterExtract {
            try? FileManager.default.trashItem(at: zip, resultingItemURL: nil)
        }
        if prefs.revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting(result.extractedTopItems)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let e as ZipWriterError:
            if case .nameNotEncodable(let name) = e {
                return L("This name cannot be stored as CP932:") + " \(name)"
            }
            return "\(e)"
        case let e as ZipReaderError:
            switch e {
            case .sizeExceedsDeclared(let name):
                return L("An entry expands far beyond the size the archive declares — it may be a decompression bomb.")
                    + "\n\(name)"
            case .overlappingEntries:
                return L("The archive's entries share overlapping data — it is malformed or a decompression bomb.")
            case .crcMismatch, .authenticationFailed:
                return L("The archive is damaged or was tampered with.")
            case .notAZipFile:
                return L("This file is not a ZIP archive.")
            default:
                return "\(e)"
            }
        case let e as Unpacker.Failure:
            switch e {
            case .insufficientSpace(let required, let available):
                return L("Not enough free space to extract this archive.")
                    + "\n" + L("Needed:") + " \(byteString(required))  "
                    + L("Available:") + " \(byteString(available))"
            case .emptyArchive:
                return L("The archive contains nothing that can be extracted.")
            case .destinationNotADirectory:
                return L("The destination is not a folder.")
            }
        default:
            return error.localizedDescription
        }
    }

    private static func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
