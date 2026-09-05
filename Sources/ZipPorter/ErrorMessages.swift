import Foundation
import ZipPorterCore

/// Engine errors → what the person sees. One place for both front ends,
/// pure so it can be tested: the GUI shows `describe`, the CLI reuses
/// `takenName` for the one failure that is neither a reader nor a writer
/// error — a name another process took while the extraction ran.
enum ErrorMessages {
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as ZipWriterError:
            switch e {
            case .nameNotEncodable(let name):
                return L("This name cannot be stored as CP932:") + " \(name)"
            case .ioError(let detail):
                return L("The archive could not be written.") + "\n\(detail)"
            default:
                return "\(e)"
            }
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
            case .corrupt(let detail):
                return L("The archive is malformed and was refused.") + "\n\(detail)"
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
            if let name = takenName(from: error) {
                return L("Another item appeared at a name this extraction was about to use, so nothing was extracted. Try again.")
                    + "\n\(name)"
            }
            return error.localizedDescription
        }
    }

    /// The item name when `error` is the exclusive create's `EEXIST` — the
    /// ADR-0005 outcome of a name taken between the uniqueness check and
    /// the create; nil for any other error.
    static func takenName(from error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EEXIST) else { return nil }
        let path = nsError.userInfo[NSFilePathErrorKey] as? String ?? ""
        return path.isEmpty ? "?" : (path as NSString).lastPathComponent
    }

    static func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
