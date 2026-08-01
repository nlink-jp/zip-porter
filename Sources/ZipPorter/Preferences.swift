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

    var destinationMode: DestinationMode = .sameFolder
    var fixedDestinationPath: String?
    var wrapMode: WrapMode = .onlyMultiple
    var folderDate: FolderDateMode = .now
    var revealInFinder = true
    var trashArchiveAfterExtract = false

    private enum Key {
        static let usePassword = "pack.usePassword"
        static let cp932 = "pack.cp932"
        static let zipCrypto = "pack.zipCrypto"
        static let skipOptions = "pack.skipOptions"
        static let revealCreated = "pack.revealCreated"
        static let destinationMode = "unpack.destinationMode"
        static let fixedDestination = "unpack.fixedDestination"
        static let wrapMode = "unpack.wrapMode"
        static let folderDate = "unpack.folderDate"
        static let revealInFinder = "unpack.revealInFinder"
        static let trashArchive = "unpack.trashArchive"
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
        // A fixed destination that disappeared falls back to same-folder.
        if p.destinationMode == .fixed {
            var isDir: ObjCBool = false
            if p.fixedDestinationPath == nil
                || !FileManager.default.fileExists(atPath: p.fixedDestinationPath!, isDirectory: &isDir)
                || !isDir.boolValue {
                p.destinationMode = .sameFolder
            }
        }
        return p
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(usePassword, forKey: Key.usePassword)
        defaults.set(cp932, forKey: Key.cp932)
        defaults.set(zipCrypto, forKey: Key.zipCrypto)
        defaults.set(skipOptions, forKey: Key.skipOptions)
        defaults.set(revealCreatedArchive, forKey: Key.revealCreated)
        defaults.set(destinationMode.rawValue, forKey: Key.destinationMode)
        defaults.set(fixedDestinationPath, forKey: Key.fixedDestination)
        defaults.set(wrapMode.rawValue, forKey: Key.wrapMode)
        defaults.set(folderDate.rawValue, forKey: Key.folderDate)
        defaults.set(revealInFinder, forKey: Key.revealInFinder)
        defaults.set(trashArchiveAfterExtract, forKey: Key.trashArchive)
    }
}
