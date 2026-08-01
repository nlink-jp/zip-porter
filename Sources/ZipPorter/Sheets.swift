import AppKit

/// Thread-safe cancellation flag shared between the UI (Cancel button) and
/// the background operation's shouldCancel poll.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Result of the pack options sheet.
struct PackSheetResult {
    var password: String?
    var cp932: Bool
    var zipCrypto: Bool
    var skipNext: Bool
}

/// The per-drop options sheet (RFP: shown on every drop; skippable via the
/// "don't show again" checkbox as long as no password is requested).
@MainActor
final class PackOptionsSheet: NSObject {
    private let sheet: NSWindow
    private let passwordCheck = NSButton(checkboxWithTitle: L("Password protect"), target: nil, action: nil)
    private let passwordField = NSSecureTextField()
    private let verifyField = NSSecureTextField()
    private let passwordLabel = NSTextField(labelWithString: L("Password:"))
    private let verifyLabel = NSTextField(labelWithString: L("Verify:"))
    private let cp932Check = NSButton(checkboxWithTitle: L("Windows legacy filenames (CP932)"), target: nil, action: nil)
    private let zipCryptoCheck = NSButton(checkboxWithTitle: L("Use ZipCrypto (weak; extractable by Explorer alone)"), target: nil, action: nil)
    private let skipCheck = NSButton(checkboxWithTitle: L("Don't show these options again"), target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private var completion: ((PackSheetResult?) -> Void)?
    private var retainedSelf: PackOptionsSheet?

    init(prefs: Preferences) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        passwordCheck.state = prefs.usePassword ? .on : .off
        cp932Check.state = prefs.cp932 ? .on : .off
        zipCryptoCheck.state = prefs.zipCrypto ? .on : .off
        passwordCheck.target = self
        passwordCheck.action = #selector(toggledPassword)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        passwordField.placeholderString = ""
        verifyField.placeholderString = ""

        let passwordRow = NSStackView(views: [passwordLabel, passwordField])
        let verifyRow = NSStackView(views: [verifyLabel, verifyField])
        for (label, field) in [(passwordLabel, passwordField), (verifyLabel, verifyField)] {
            label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            label.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }

        let okButton = NSButton(title: L("Create ZIP"), target: self, action: #selector(confirmed))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelled))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [skipCheck, NSView(), cancelButton, okButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            passwordCheck, passwordRow, verifyRow, errorLabel,
            cp932Check, zipCryptoCheck, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
        toggledPassword()
    }

    @objc private func toggledPassword() {
        let on = passwordCheck.state == .on
        for control in [passwordField, verifyField] { control.isEnabled = on }
        zipCryptoCheck.isEnabled = on
        if !on { errorLabel.isHidden = true }
    }

    @objc private func confirmed() {
        var password: String?
        if passwordCheck.state == .on {
            let first = passwordField.stringValue
            guard !first.isEmpty else {
                errorLabel.stringValue = L("Enter a password")
                errorLabel.isHidden = false
                return
            }
            guard first == verifyField.stringValue else {
                errorLabel.stringValue = L("Passwords do not match")
                errorLabel.isHidden = false
                return
            }
            password = first
        }
        finish(PackSheetResult(
            password: password,
            cp932: cp932Check.state == .on,
            zipCrypto: passwordCheck.state == .on && zipCryptoCheck.state == .on,
            skipNext: skipCheck.state == .on))
    }

    @objc private func cancelled() { finish(nil) }

    private func finish(_ result: PackSheetResult?) {
        guard let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        completion?(result)
        completion = nil
        retainedSelf = nil
    }

    func present(on window: NSWindow, completion: @escaping (PackSheetResult?) -> Void) {
        self.completion = completion
        retainedSelf = self
        window.beginSheet(sheet)
    }
}

/// Password prompt for extracting an encrypted archive.
@MainActor
final class PasswordSheet: NSObject {
    private let sheet: NSWindow
    private let field = NSSecureTextField()
    private var completion: ((String?) -> Void)?
    private var retainedSelf: PasswordSheet?

    init(message: String) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        let title = NSTextField(labelWithString: L("Password required"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let okButton = NSButton(title: L("Extract"), target: self, action: #selector(confirmed))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelled))
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, messageLabel, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
    }

    @objc private func confirmed() { finish(field.stringValue) }
    @objc private func cancelled() { finish(nil) }

    private func finish(_ result: String?) {
        guard let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        completion?(result)
        completion = nil
        retainedSelf = nil
    }

    func present(on window: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        retainedSelf = self
        window.beginSheet(sheet)
        sheet.makeFirstResponder(field)
    }
}

/// Indeterminate progress sheet with a Cancel button; `flag` is polled by
/// the background operation.
@MainActor
final class ProgressSheet: NSObject {
    let flag = CancellationFlag()
    private let sheet: NSWindow
    private let label = NSTextField(labelWithString: L("Preparing…"))
    private let indicator = NSProgressIndicator()
    private var retainedSelf: ProgressSheet?

    init(title: String) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
                         styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed))
        let buttons = NSStackView(views: [NSView(), cancelButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, indicator, label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
    }

    @objc private func cancelPressed() { flag.cancel() }

    func begin(on window: NSWindow) {
        retainedSelf = self
        window.beginSheet(sheet)
        indicator.startAnimation(nil)
    }

    func update(_ text: String) {
        label.stringValue = text
    }

    func end() {
        indicator.stopAnimation(nil)
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        retainedSelf = nil
    }
}
