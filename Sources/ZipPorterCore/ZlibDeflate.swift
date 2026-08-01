import CZlib
import Foundation

/// Raw-deflate encoding on the system zlib (ADR-014). Level 6 output is
/// both smaller and — with the parallel paths — faster than the Compression
/// framework encoder this replaces. Inflate stays on the Compression
/// framework; the streams produced here are standard deflate.
enum ZlibDeflate {
    static let level: Int32 = 6
    /// -15: raw deflate, no zlib header — what ZIP entries store.
    private static let rawWindowBits: Int32 = -15

    enum Failure: Error {
        case initFailed
        case deflateFailed(Int32)
    }

    /// Compress one independent block of a larger stream.
    ///
    /// Non-final blocks end with `Z_SYNC_FLUSH`: byte-aligned, no BFINAL
    /// bit, so blocks concatenate into one valid deflate stream (the pigz
    /// join). The final block ends with `Z_FINISH`.
    static func compressBlock(_ input: Data, isLast: Bool) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, rawWindowBits, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.initFailed
        }
        defer { deflateEnd(&stream) }

        let bound = deflateBound(&stream, uLong(input.count))
        var output = Data(count: Int(bound) + 64)
        let produced: Int = try input.withUnsafeBytes { (inRaw: UnsafeRawBufferPointer) in
            try output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inRaw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outRaw.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(outRaw.count)
                let flush = isLast ? Z_FINISH : Z_SYNC_FLUSH
                let status = deflate(&stream, flush)
                let expected = isLast ? Z_STREAM_END : Z_OK
                guard status == expected, stream.avail_in == 0 else {
                    throw Failure.deflateFailed(status)
                }
                return outRaw.count - Int(stream.avail_out)
            }
        }
        output.removeSubrange(produced..<output.count)
        return output
    }

    /// Streaming CRC-32 on zlib's SIMD implementation (same polynomial as
    /// our CRC32 type, an order of magnitude faster on large buffers).
    static func crc32(_ running: UInt32, _ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return running }
            return UInt32(CZlib.crc32(uLong(running),
                                      base.assumingMemoryBound(to: Bytef.self),
                                      uInt(raw.count)))
        }
    }
}

/// Streaming counterpart for the sequential paths (small entries, the
/// writer's fallback) — same API shape as DeflateStream so call sites can
/// swap encoders without restructuring.
final class ZlibDeflateStream {
    enum Failure: Error {
        case initFailed
        case deflateFailed(Int32)
    }

    private var stream = z_stream()
    private var finished = false
    private let bufferSize = 128 << 10
    private let buffer: UnsafeMutablePointer<UInt8>

    init() throws {
        buffer = .allocate(capacity: bufferSize)
        guard deflateInit2_(&stream, ZlibDeflate.level, Z_DEFLATED, -15, 8,
                            Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            buffer.deallocate()
            throw Failure.initFailed
        }
    }

    deinit {
        deflateEnd(&stream)
        buffer.deallocate()
    }

    func process(_ input: Data, final: Bool, sink: (Data) throws -> Void) throws {
        guard !finished else { return }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(
                mutating: raw.bindMemory(to: UInt8.self).baseAddress) ?? buffer
            stream.avail_in = uInt(raw.count)
            let flush = final ? Z_FINISH : Z_NO_FLUSH
            while true {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                let status = deflate(&stream, flush)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw Failure.deflateFailed(status)
                }
                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 {
                    try sink(Data(bytes: buffer, count: produced))
                }
                if status == Z_STREAM_END {
                    finished = true
                    return
                }
                if stream.avail_in == 0 && produced < bufferSize && !final {
                    return
                }
                if status == Z_BUF_ERROR && produced == 0 {
                    // Nothing to consume and nothing produced.
                    return
                }
            }
        }
    }
}
