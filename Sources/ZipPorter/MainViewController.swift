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
    /// Whole requests that arrived while another was running — a second
    /// Finder double-click, typically. They run in turn; `workDidFinish`
    /// waits until the last of them is done.
    private var pendingRequests: [[URL]] = []
    private var busy = false {
        didSet {
            if !busy { startNextRequestOrFinish() }
        }
    }

    /// True from the moment a request starts until its result is dismissed —
    /// including while a password prompt or options sheet is waiting on the
    /// user. The delegate must not quit the process in that state.
    var isBusy: Bool { busy || !pendingRequests.isEmpty }

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
        // Dropping or double-clicking a second archive while the first is
        // still running used to be answered with a beep and nothing else —
        // from a Finder launch, with no window on screen, that is silent
        // data loss. Queue it instead.
        guard !busy else {
            pendingRequests.append(urls)
            return
        }
        start(urls)
    }

    /// All-ZIP requests extract; anything else packs (a mixed drop stores
    /// the ZIPs as plain files).
    private func start(_ urls: [URL]) {
        let zips = urls.filter { $0.pathExtension.lowercased() == "zip" }
        if zips.count == urls.count {
            startUnpackBatch(zips)
        } else {
            startPack(urls)
        }
    }

    /// Runs on every transition out of `busy`. `workDidFinish` — which the
    /// delegate uses to quit a Finder launch — fires only once nothing is
    /// left to do.
    private func startNextRequestOrFinish() {
        guard !pendingRequests.isEmpty else {
            workDidFinish?()
            return
        }
        let next = pendingRequests.removeFirst()
        // Hop off this `didSet`: `start` sets `busy` again, and re-entering
        // the observer from inside itself is how ordering bugs get in.
        DispatchQueue.main.async { [weak self] in self?.start(next) }
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
                                                summary: summary,
                                                reveal: [result.outputURL], done: done)
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
    /// always get the dialog (ADR-0001).
    private func announceCompletion(sheet: OperationSheet,
                                    title: String,
                                    summary: String,
                                    reveal: [URL],
                                    done: @escaping @MainActor () -> Void) {
        switch Preferences.load().completionStyle {
        case .notification:
            sheet.dismiss()
            CompletionNotifier.shared.notify(
                title: title,
                body: summary.replacingOccurrences(of: "\n", with: " — "),
                reveal: reveal,
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

    /// A request — one Finder multi-selection, one drop — is extracted as a
    /// single batch: one progress sheet, one destination question, one
    /// result, one Finder reveal (ADR-0004).
    private func startUnpackBatch(_ zips: [URL]) {
        busy = true
        CompletionNotifier.shared.prepare()
        let prefs = Preferences.load()
        // Asked once for the whole request. Per archive it was one panel per
        // double-clicked file, which is not a decision anyone wants to make
        // three times.
        resolveDestination(prefs) { [weak self] destination, cancelled in
            guard let self else { return }
            guard !cancelled else {
                self.busy = false
                return
            }
            self.runUnpackBatch(zips, destination: destination, prefs: prefs)
        }
    }

    private func runUnpackBatch(_ zips: [URL], destination: URL?, prefs: Preferences) {
        let sheet = OperationSheet(title: L("Extracting…"))
        sheet.begin(on: hostWindow)
        let progress = BatchProgress(sizes: zips.map(Self.fileSize))
        var batch = ExtractionBatch(requested: zips.count)
        // Archives handed out together almost always share one password;
        // carrying it forward turns N prompts into one.
        var password: String?
        var index = 0

        func step() {
            guard index < zips.count, !sheet.flag.isCancelled else {
                batch.cancelled = sheet.flag.isCancelled && index < zips.count
                self.finishBatch(sheet: sheet, batch: batch, prefs: prefs)
                return
            }
            let zip = zips[index]
            let position = index
            if zips.count > 1 {
                sheet.setScope(String(format: L("%1$d of %2$d — %3$@"),
                                      position + 1, zips.count, zip.lastPathComponent))
            }
            self.unpackOne(
                zip, password: password, destination: destination, prefs: prefs, sheet: sheet,
                progress: { fraction in
                    sheet.setFraction(progress.overall(index: position, fraction: fraction))
                },
                completion: { outcome in
                    switch outcome {
                    case .done(let archiveOutcome, let accepted):
                        password = accepted ?? password
                        batch.record(archiveOutcome)
                    case .failed(let reason):
                        batch.record(ExtractionBatch.Failure(
                            archive: zip.lastPathComponent, reason: reason))
                    case .cancelled:
                        batch.cancelled = true
                        self.finishBatch(sheet: sheet, batch: batch, prefs: prefs)
                        return
                    }
                    index += 1
                    step()
                })
        }
        step()
    }

    /// One archive's contribution to the batch. A failure never aborts the
    /// rest of the request — it is reported at the end alongside what did
    /// come out.
    private enum ArchiveResult {
        case done(ArchiveOutcome, acceptedPassword: String?)
        case failed(reason: String)
        case cancelled
    }

    /// Weight for the batch progress bar. Zero for anything unreadable —
    /// the bar just gives that archive no share of the total.
    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func finishBatch(sheet: OperationSheet, batch: ExtractionBatch, prefs: Preferences) {
        // Nothing came out: an error, not a result with zeroes in it.
        if batch.isTotalFailure {
            sheet.dismiss()
            showError(batch.failureHeadline, batch.failureDetail)
            busy = false
            return
        }
        // Cancelled before the first archive finished — there is nothing to
        // report and the user already knows why.
        guard !batch.outcomes.isEmpty else {
            sheet.dismiss()
            busy = false
            return
        }
        let reveal = batch.topItems
        let done: @MainActor () -> Void = { [weak self] in
            if prefs.revealInFinder, !reveal.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(reveal)
            }
            self?.busy = false
        }
        let notes = batch.notes
        if notes.isEmpty {
            announceCompletion(sheet: sheet, title: batch.title,
                               summary: batch.summary, reveal: reveal, done: done)
        } else {
            sheet.finish(title: batch.title, summary: batch.summary,
                         notes: notes, completion: done)
        }
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

    /// Extracts one archive into the batch's shared sheet. Reports through
    /// `completion` instead of announcing anything itself — the batch owns
    /// the result the user sees.
    ///
    /// `password` is what the batch has already learned; `acceptedPassword`
    /// in the result hands back whatever actually worked so the next archive
    /// can try it first.
    private func unpackOne(_ zip: URL,
                           password: String?,
                           destination: URL?,
                           prefs: Preferences,
                           sheet: OperationSheet,
                           progress: @escaping @MainActor (Double) -> Void,
                           completion: @escaping (ArchiveResult) -> Void) {
        var options = Unpacker.Options()
        options.destination = destination
        options.password = password
        options.folderPolicy = prefs.wrapMode.folderPolicy
        let flag = sheet.flag
        let forwarder = ProgressForwarder { fraction, path in
            progress(fraction)
            if let path { sheet.update(path) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Unpacker.unpack(
                    zipURL: zip, options: options,
                    progress: { forwarder.forward($0) },
                    shouldCancel: { flag.isCancelled })
                DispatchQueue.main.async {
                    // Per-archive housekeeping (folder date, trashing the
                    // archive) happens here; the Finder reveal does not —
                    // that is one action for the whole batch.
                    self.finishUnpack(zip: zip, result: result, prefs: prefs)
                    completion(.done(ArchiveOutcome(archive: zip.lastPathComponent,
                                                    result: result),
                                     acceptedPassword: password))
                }
            } catch let error as ZipReaderError where Self.isPasswordProblem(error) {
                DispatchQueue.main.async {
                    let hint = error == .passwordRequired
                        ? L("This archive is encrypted.")
                        : L("Wrong password. Try again.")
                    // Hung from the operation sheet, not the droplet window:
                    // the batch sheet stays up for the whole request, and a
                    // second sheet on the same parent would queue behind it.
                    PasswordSheet(message: "\(zip.lastPathComponent) — \(hint)")
                        .present(on: sheet.nestedDialogHost) { entered in
                            guard let entered, !entered.isEmpty else {
                                // Declining the prompt is a decision about
                                // this archive, not about the batch: say so
                                // in the result and carry on.
                                completion(.failed(reason: L("Password required")))
                                return
                            }
                            self.unpackOne(zip, password: entered, destination: destination,
                                           prefs: prefs, sheet: sheet,
                                           progress: progress, completion: completion)
                        }
                }
            } catch is CancellationError {
                DispatchQueue.main.async { completion(.cancelled) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failed(reason: Self.describe(error)))
                }
            }
        }
    }

    /// Evaluated in the `catch` clause on the worker queue, before anything
    /// hops back to the main actor — it is a plain switch over an enum, so
    /// it has no business being actor-isolated.
    private nonisolated static func isPasswordProblem(_ error: ZipReaderError) -> Bool {
        switch error {
        case .passwordRequired, .wrongPassword, .authenticationFailed:
            return true
        default:
            return false
        }
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
        // The Finder reveal is deliberately not here: it happens once for
        // the whole request, in `finishBatch`.
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
