import Foundation

/// RFC 1951 inflater with the Deflate64 extension — ZIP method 9, which
/// Windows Explorer writes once an archive passes ~2 GB (ADR-0006).
///
/// Neither the Compression framework nor the system zlib decodes Deflate64,
/// so it is decoded here. Deflate64 differs from Deflate in exactly three
/// places: a 64 KiB window, distance codes 30/31 (32769 / 49153 + 14 extra
/// bits), and length code 285 meaning 3 + 16 extra bits instead of 258.
/// `.deflate` switches those back so tests can run this decoder over zlib
/// output in bulk; production calls it for method 9 only.
///
/// Strict like zlib: every malformed construct throws, none traps, and
/// every step consumes input or emits output, so no input can make it spin.
public enum Inflate64 {
    public enum Variant: Sendable { case deflate, deflate64 }

    public enum Failure: Error, Equatable {
        /// Input ended before the final block did.
        case truncated
        /// The stream breaks a rule of the format; the string says which.
        case invalid(String)
    }

    /// What the decoder saw — read by tests to prove the Deflate64-only
    /// codes actually ran, rather than assuming a fixture contains them.
    public struct Statistics: Equatable, Sendable {
        public var blocks = 0
        /// Distance codes 30/31 (Deflate64 only).
        public var longDistances = 0
        /// Length code 285 with its 16 extra bits (Deflate64 only).
        public var longLengths = 0
    }

    /// Decode one stream. `input` is pulled until the final block ends (or
    /// returns nil — truncation); `sink` receives the output in pieces.
    /// Bytes after the final block are left unread for the caller.
    @discardableResult
    public static func decode(_ variant: Variant = .deflate64,
                              input: () throws -> Data?,
                              sink: (Data) throws -> Void) throws -> Statistics {
        try withoutActuallyEscaping(input) { input in
            try withoutActuallyEscaping(sink) { sink in
                let decoder = Decoder(variant: variant, input: input, sink: sink)
                try decoder.run()
                return decoder.stats
            }
        }
    }
}

// MARK: - Tables (RFC 1951 §3.2.5; Deflate64 overrides applied in Decoder)

private let lengthBase: [Int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
]
private let lengthExtra: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
]
/// 32 entries: 30 and 31 exist only in Deflate64.
private let distanceBase: [Int] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
    16385, 24577, 32769, 49153,
]
private let distanceExtra: [Int] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14,
]
/// Order in which code-length code lengths are stored.
private let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/// Canonical Huffman code: a direct table for codes up to `fastBits` long,
/// and the canonical counts/symbols walk (as in zlib's puff) beyond that.
private struct Huffman {
    static let fastBits = 10
    static let maxBits = 15

    /// Indexed by the next `fastBits` stream bits: `symbol | length << 9`,
    /// 0 when no code that short starts with those bits.
    var fast: [UInt16]
    var counts: [Int]
    var symbols: [UInt16]

    /// `allowIncomplete` admits what zlib admits for literal/length and
    /// distance codes: no codes at all (decoding one then fails) or a
    /// single one-bit code. Code-length codes must be complete.
    init(lengths: ArraySlice<UInt8>, allowIncomplete: Bool) throws {
        counts = Array(repeating: 0, count: Self.maxBits + 1)
        for length in lengths { counts[Int(length)] += 1 }
        let used = lengths.count - counts[0]

        var left = 1
        for length in 1...Self.maxBits {
            left <<= 1
            left -= counts[length]
            guard left >= 0 else { throw Inflate64.Failure.invalid("over-subscribed Huffman code") }
        }
        if left > 0 {
            let tolerated = used == 0 || (used == 1 && counts[1] == 1)
            guard allowIncomplete, tolerated else {
                throw Inflate64.Failure.invalid("incomplete Huffman code")
            }
        }

        var offsets = Array(repeating: 0, count: Self.maxBits + 1)
        for length in 1..<Self.maxBits { offsets[length + 1] = offsets[length] + counts[length] }
        symbols = Array(repeating: 0, count: used)
        for (symbol, length) in zip(0..., lengths) where length != 0 {
            symbols[offsets[Int(length)]] = UInt16(symbol)
            offsets[Int(length)] += 1
        }

        fast = Array(repeating: 0, count: 1 << Self.fastBits)
        var code = 0
        var index = 0
        for length in 1...Self.maxBits {
            for _ in 0..<counts[length] {
                if length <= Self.fastBits {
                    // Codes are sent most-significant bit first into an
                    // LSB-first bit stream, so the table is keyed reversed.
                    var reversed = 0
                    for bit in 0..<length where code & (1 << bit) != 0 {
                        reversed |= 1 << (length - 1 - bit)
                    }
                    let entry = UInt16(length << 9) | symbols[index]
                    var slot = reversed
                    while slot < 1 << Self.fastBits {
                        fast[slot] = entry
                        slot += 1 << length
                    }
                }
                code += 1
                index += 1
            }
            code <<= 1
        }
    }

    static func fixed(_ variant: Inflate64.Variant) -> (literal: Huffman, distance: Huffman) {
        var literal = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { literal[i] = 9 }
        for i in 256..<280 { literal[i] = 7 }
        // 32 five-bit distance codes in both variants; Deflate rejects 30/31
        // when decoded, as RFC 1951 specifies.
        let distance = [UInt8](repeating: 5, count: 32)
        // Both codes are complete by construction.
        return (try! Huffman(lengths: literal[...], allowIncomplete: false),
                try! Huffman(lengths: distance[...], allowIncomplete: false))
    }
}

// MARK: - Decoder

private final class Decoder {
    let variant: Inflate64.Variant
    let input: () throws -> Data?
    let sink: (Data) throws -> Void
    var stats = Inflate64.Statistics()

    // Input: the current chunk and an LSB-first bit buffer.
    private var chunk: [UInt8] = []
    private var position = 0
    private var inputEnded = false
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0

    // Output: `window` bytes of history, then staged output. Flushed to
    // `sink` at `flushAt`; one match (≤ 65538) or one stored block
    // (≤ 65535) past that still fits in `capacity`.
    private let window: Int
    private let flushAt: Int
    private let output: UnsafeMutablePointer<UInt8>
    private var outputLength = 0
    private var unflushed = 0
    private let distanceCodes: Int

    init(variant: Inflate64.Variant,
         input: @escaping () throws -> Data?,
         sink: @escaping (Data) throws -> Void) {
        self.variant = variant
        self.input = input
        self.sink = sink
        window = variant == .deflate64 ? 1 << 16 : 1 << 15
        distanceCodes = variant == .deflate64 ? 32 : 30
        flushAt = window + (256 << 10)
        output = .allocate(capacity: flushAt + 65_538)
    }

    deinit { output.deallocate() }

    func run() throws {
        var fixed: (literal: Huffman, distance: Huffman)?
        var final = false
        repeat {
            final = try bits(1) == 1
            stats.blocks += 1
            switch try bits(2) {
            case 0:
                try storedBlock()
            case 1:
                if fixed == nil { fixed = Huffman.fixed(variant) }
                try codedBlock(fixed!.literal, fixed!.distance)
            case 2:
                let tables = try dynamicTables()
                try codedBlock(tables.literal, tables.distance)
            default:
                throw Inflate64.Failure.invalid("reserved block type")
            }
        } while !final
        try flush()
    }

    // MARK: Bits

    private func nextChunk() throws -> Bool {
        while !inputEnded {
            guard let data = try input() else {
                inputEnded = true
                break
            }
            if !data.isEmpty {
                chunk = [UInt8](data)
                position = 0
                return true
            }
        }
        return false
    }

    /// Fill the bit buffer as far as input allows, without failing at EOF —
    /// a Huffman lookup peeks further than the code it finds may need.
    private func fill() throws {
        while bitCount <= 56 {
            if position == chunk.count {
                guard try nextChunk() else { return }
            }
            bitBuffer |= UInt64(chunk[position]) << UInt64(bitCount)
            position += 1
            bitCount += 8
        }
    }

    private func bits(_ count: Int) throws -> Int {
        if bitCount < count {
            try fill()
            guard bitCount >= count else { throw Inflate64.Failure.truncated }
        }
        let value = Int(bitBuffer & ((1 << UInt64(count)) - 1))
        bitBuffer >>= UInt64(count)
        bitCount -= count
        return value
    }

    private func decode(_ code: Huffman) throws -> Int {
        if bitCount < Huffman.maxBits { try fill() }
        let entry = code.fast[Int(bitBuffer & ((1 << UInt64(Huffman.fastBits)) - 1))]
        if entry != 0 {
            let length = Int(entry >> 9)
            guard length <= bitCount else { throw Inflate64.Failure.truncated }
            bitBuffer >>= UInt64(length)
            bitCount -= length
            return Int(entry & 0x1FF)
        }
        // Longer than the table, or unassigned: walk the canonical code.
        var value = 0
        var first = 0
        var index = 0
        for length in 1...Huffman.maxBits {
            guard length <= bitCount else { throw Inflate64.Failure.truncated }
            value |= Int((bitBuffer >> UInt64(length - 1)) & 1)
            let count = code.counts[length]
            if value >= first, value - first < count {
                bitBuffer >>= UInt64(length)
                bitCount -= length
                return Int(code.symbols[index + value - first])
            }
            index += count
            first = (first + count) << 1
            value <<= 1
        }
        throw Inflate64.Failure.invalid("unassigned Huffman code")
    }

    // MARK: Blocks

    private func storedBlock() throws {
        let partial = bitCount & 7
        bitBuffer >>= UInt64(partial)
        bitCount -= partial
        let length = try bits(16)
        guard try bits(16) == length ^ 0xFFFF else {
            throw Inflate64.Failure.invalid("stored block length check failed")
        }
        var remaining = length
        // Whole bytes already pulled into the bit buffer come first.
        while remaining > 0, bitCount >= 8 {
            output[outputLength] = UInt8(truncatingIfNeeded: bitBuffer)
            outputLength += 1
            bitBuffer >>= 8
            bitCount -= 8
            remaining -= 1
        }
        while remaining > 0 {
            if position == chunk.count {
                guard try nextChunk() else { throw Inflate64.Failure.truncated }
            }
            let n = min(remaining, chunk.count - position)
            chunk.withUnsafeBufferPointer { source in
                (output + outputLength).update(from: source.baseAddress! + position, count: n)
            }
            position += n
            outputLength += n
            remaining -= n
        }
        if outputLength >= flushAt { try flush() }
    }

    private func codedBlock(_ literal: Huffman, _ distance: Huffman) throws {
        while true {
            // Checked before every symbol, literals included, so the
            // staging area never holds more than one symbol past flushAt.
            if outputLength >= flushAt { try flush() }
            let symbol = try decode(literal)
            if symbol < 256 {
                output[outputLength] = UInt8(symbol)
                outputLength += 1
                continue
            }
            if symbol == 256 { break }

            let lengthCode = symbol - 257
            guard lengthCode < 29 else { throw Inflate64.Failure.invalid("invalid length symbol \(symbol)") }
            let length: Int
            if lengthCode == 28, variant == .deflate64 {
                length = try 3 + bits(16)
                stats.longLengths += 1
            } else {
                length = try lengthBase[lengthCode] + bits(lengthExtra[lengthCode])
            }

            let distanceCode = try decode(distance)
            guard distanceCode < distanceCodes else {
                throw Inflate64.Failure.invalid("invalid distance symbol \(distanceCode)")
            }
            let back = try distanceBase[distanceCode] + bits(distanceExtra[distanceCode])
            if distanceCode >= 30 { stats.longDistances += 1 }
            // Once history is compacted outputLength stays ≥ window ≥ any
            // encodable distance, so this only bites near the stream start.
            guard back <= outputLength else {
                throw Inflate64.Failure.invalid("distance reaches before the start of output")
            }

            let target = output + outputLength
            let source = target - back
            if back >= length {
                target.update(from: source, count: length)
            } else {
                // Overlapping copy repeats the last `back` bytes: forward,
                // one byte at a time, is the definition.
                for i in 0..<length { target[i] = source[i] }
            }
            outputLength += length
        }
        if outputLength >= flushAt { try flush() }
    }

    private func dynamicTables() throws -> (literal: Huffman, distance: Huffman) {
        let literalCount = try bits(5) + 257
        let distanceCount = try bits(5) + 1
        let codeLengthCount = try bits(4) + 4
        guard literalCount <= 286 else { throw Inflate64.Failure.invalid("too many length codes") }
        guard distanceCount <= distanceCodes else { throw Inflate64.Failure.invalid("too many distance codes") }

        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[i]] = UInt8(try bits(3))
        }
        let codeLengths = try Huffman(lengths: codeLengthLengths[...], allowIncomplete: false)

        let total = literalCount + distanceCount
        var lengths = [UInt8](repeating: 0, count: total)
        var i = 0
        while i < total {
            let symbol = try decode(codeLengths)
            if symbol < 16 {
                lengths[i] = UInt8(symbol)
                i += 1
                continue
            }
            var value: UInt8 = 0
            let run: Int
            switch symbol {
            case 16:
                guard i > 0 else { throw Inflate64.Failure.invalid("repeat with no previous length") }
                value = lengths[i - 1]
                run = try 3 + bits(2)
            case 17:
                run = try 3 + bits(3)
            default:
                run = try 11 + bits(7)
            }
            guard run <= total - i else { throw Inflate64.Failure.invalid("code lengths overrun") }
            for _ in 0..<run {
                lengths[i] = value
                i += 1
            }
        }
        guard lengths[256] != 0 else { throw Inflate64.Failure.invalid("no end-of-block code") }
        return (try Huffman(lengths: lengths[0..<literalCount], allowIncomplete: true),
                try Huffman(lengths: lengths[literalCount...], allowIncomplete: true))
    }

    // MARK: Output

    /// Hand staged output to the sink and keep the last `window` bytes as
    /// history for later distances.
    private func flush() throws {
        if outputLength > unflushed {
            try sink(Data(bytes: output + unflushed, count: outputLength - unflushed))
        }
        if outputLength > window {
            memmove(output, output + (outputLength - window), window)
            outputLength = window
        }
        unflushed = outputLength
    }
}
