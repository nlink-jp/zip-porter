import Foundation
import ZipPorterCore

/// Remembered GUI settings. The password VALUE is never stored — only
/// whether the checkbox was on.
struct Preferences {
    // MARK: Pack sheet
    var usePassword = false
    var cp932 = false
    var zipCrypto = false
    /// When true (and no password is requested), drops pack immediately
    /// without showing the options sheet.
    var skipOptions = false
    var revealCreatedArchive = true
    /// Where a new archive is written — the creation-side mirror of the
    /// extraction destination setting.
    var packDestinationMode: DestinationMode = .sameFolder
    var packFixedDestinationPath: String?

    // MARK: Extraction (The Unarchiver-style)
    enum DestinationMode: String {
        case sameFolder
        case ask
        case fixed
    }

    enum WrapMode: String {
        case never
        case onlyMultiple
        case always

        var folderPolicy: Unpacker.FolderPolicy {
            switch self {
            case .never: return .never
            case .onlyMultiple: return .onlyMultipleTopLevel
            case .always: return .always
            }
        }
    }

    enum FolderDateMode: String {
        case now
        case archive
    }

    /// How a clean finish is announced. Anything worth reading — skipped
    /// unsafe paths, renamed duplicates, errors — always uses a dialog
    /// regardless of this setting (ADR-012: those must not be silent).
    enum CompletionStyle: String {
        case notification
        case dialog
        case silent
    }

    var destinationMode: DestinationMode = .sameFolder
    var fixedDestinationPath: String?
    var wrapMode: WrapMode = .onlyMultiple
    var folderDate: FolderDateMode = .now
    var revealInFinder = true
    var trashArchiveAfterExtract = false

    // MARK: Shared
    var completionStyle: CompletionStyle = .notification

    private enum Key {
        static let usePassword = "pack.usePassword"
        static let cp932 = "pack.cp932"
        static let zipCrypto = "pack.zipCrypto"
        static let skipOptions = "pack.skipOptions"
        static let revealCreated = "pack.revealCreated"
        static let packDestinationMode = "pack.destinationMode"
        static let packFixedDestination = "pack.fixedDestination"
        static let destinationMode = "unpack.destinationMode"
        static let fixedDestination = "unpack.fixedDestination"
        static let wrapMode = "unpack.wrapMode"
        static let folderDate = "unpack.folderDate"
        static let revealInFinder = "unpack.revealInFinder"
        static let trashArchive = "unpack.trashArchive"
        static let completionStyle = "completionStyle"
    }

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        var p = Preferences()
        p.usePassword = defaults.bool(forKey: Key.usePassword)
        p.cp932 = defaults.bool(forKey: Key.cp932)
        p.zipCrypto = defaults.bool(forKey: Key.zipCrypto)
        p.skipOptions = defaults.bool(forKey: Key.skipOptions)
        p.revealCreatedArchive = defaults.object(forKey: Key.revealCreated) == nil
            ? true
            : defaults.bool(forKey: Key.revealCreated)
        p.packDestinationMode = (defaults.string(forKey: Key.packDestinationMode)
            .flatMap(DestinationMode.init(rawValue:))) ?? .sameFolder
        p.packFixedDestinationPath = defaults.string(forKey: Key.packFixedDestination)
        p.destinationMode = (defaults.string(forKey: Key.destinationMode)
            .flatMap(DestinationMode.init(rawValue:))) ?? .sameFolder
        p.fixedDestinationPath = defaults.string(forKey: Key.fixedDestination)
        p.wrapMode = (defaults.string(forKey: Key.wrapMode)
            .flatMap(WrapMode.init(rawValue:))) ?? .onlyMultiple
        p.folderDate = (defaults.string(forKey: Key.folderDate)
            .flatMap(FolderDateMode.init(rawValue:))) ?? .now
        p.revealInFinder = defaults.object(forKey: Key.revealInFinder) == nil
            ? true
            : defaults.bool(forKey: Key.revealInFinder)
        p.trashArchiveAfterExtract = defaults.bool(forKey: Key.trashArchive)
        p.completionStyle = (defaults.string(forKey: Key.completionStyle)
            .flatMap(CompletionStyle.init(rawValue:))) ?? .notification
        // A fixed destination that disappeared falls back to same-folder.
        if !Self.isUsableDirectory(p.fixedDestinationPath) {
            if p.destinationMode == .fixed { p.destinationMode = .sameFolder }
        }
        if !Self.isUsableDirectory(p.packFixedDestinationPath) {
            if p.packDestinationMode == .fixed { p.packDestinationMode = .sameFolder }
        }
        return p
    }

    private static func isUsableDirectory(_ path: String?) -> Bool {
        guard let path else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(usePassword, forKey: Key.usePassword)
        defaults.set(cp932, forKey: Key.cp932)
        defaults.set(zipCrypto, forKey: Key.zipCrypto)
        defaults.set(skipOptions, forKey: Key.skipOptions)
        defaults.set(revealCreatedArchive, forKey: Key.revealCreated)
        defaults.set(packDestinationMode.rawValue, forKey: Key.packDestinationMode)
        defaults.set(packFixedDestinationPath, forKey: Key.packFixedDestination)
        defaults.set(destinationMode.rawValue, forKey: Key.destinationMode)
        defaults.set(fixedDestinationPath, forKey: Key.fixedDestination)
        defaults.set(wrapMode.rawValue, forKey: Key.wrapMode)
        defaults.set(folderDate.rawValue, forKey: Key.folderDate)
        defaults.set(revealInFinder, forKey: Key.revealInFinder)
        defaults.set(trashArchiveAfterExtract, forKey: Key.trashArchive)
        defaults.set(completionStyle.rawValue, forKey: Key.completionStyle)
    }
}
