import Foundation
@testable import ZipPorterCore

/// Helpers shared by the engine tests.
enum TestSupport {
    /// Run an external tool and capture its combined output.
    ///
    /// Under a UTF-8 locale `unzip -t` prints Japanese names with `?`
    /// substituted *inside* multibyte sequences, so its output is not valid
    /// UTF-8 and a strict decode yields "" — assertions on the text then
    /// fail on the developer's locale and pass on another. The C locale
    /// makes the output the same everywhere.
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
            .merging(["LC_ALL": "C"]) { _, pinned in pinned }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Deterministic pseudo-random bytes, one LCG step per byte mapped by `map`.
    static func bytes(_ count: Int, seed: UInt64, _ map: (UInt64) -> UInt8) -> Data {
        var x = seed | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<count {
                x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[i] = map(x)
            }
        }
        return data
    }

    /// Incompressible bytes: deflate output ≈ input size, and the
    /// worth-deflating probe says no.
    static func noise(_ count: Int, seed: UInt64) -> Data {
        bytes(count, seed: seed) { UInt8(truncatingIfNeeded: $0 >> 33) }
    }

    /// Sixteen-symbol text: deflates to roughly half, so the probe says yes.
    static func symbols(_ count: Int, seed: UInt64) -> Data {
        bytes(count, seed: seed) { UInt8(ascii: "a") + UInt8(truncatingIfNeeded: ($0 >> 33) & 15) }
    }

    /// Scratch arenas left in `directory` — must be empty after any pack.
    static func scratchLeftovers(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(ScratchArena.namePrefix) }
    }

    /// A `shouldCancel` that flips after `n` polls. Polled from the
    /// compression workers concurrently, so the count is locked.
    final class CancelAfter {
        private let lock = NSLock()
        private let limit: Int
        private var polls = 0

        init(_ limit: Int) { self.limit = limit }

        func poll() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            polls += 1
            return polls > limit
        }
    }
}
