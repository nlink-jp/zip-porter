import Darwin
import Foundation

/// A byte buffer that is wiped when the last reference to it goes away.
///
/// This is best-effort and deliberately modest about it: Swift copies
/// values freely, so nothing here can promise that no copy of a key ever
/// existed elsewhere in memory. What it does buy is that the buffer the
/// cipher actually uses for the length of an operation does not survive in
/// freed heap memory afterwards — the cheap half of the problem, and the
/// half that lasts longest.
final class ZeroingBytes {
    private let storage: UnsafeMutableBufferPointer<UInt8>

    var pointer: UnsafePointer<UInt8> { UnsafePointer(storage.baseAddress!) }
    var count: Int { storage.count }

    init(_ source: [UInt8]) {
        storage = .allocate(capacity: max(source.count, 1))
        _ = storage.initialize(from: source)
    }

    deinit {
        wipe(storage.baseAddress, storage.count)
        storage.deallocate()
    }
}

/// Overwrite a buffer in a way the optimizer may not drop as dead. Used on
/// key material the moment it stops being needed.
func wipe(_ base: UnsafeMutableRawPointer?, _ count: Int) {
    guard let base, count > 0 else { return }
    memset_s(base, count, 0, count)
}

extension Array where Element == UInt8 {
    /// Zero the array's own storage in place.
    mutating func wipeContents() {
        withUnsafeMutableBytes { wipe($0.baseAddress, $0.count) }
    }
}
