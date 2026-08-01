import Compression
import Foundation

/// Raw DEFLATE (RFC 1951) streaming codec over Apple's Compression framework
/// (COMPRESSION_ZLIB is raw deflate without the zlib wrapper, despite the name
/// — exactly what ZIP method 8 stores).
public final class DeflateStream {
    public enum Mode { case compress, decompress }
    public enum Failure: Error { case initFailed, corruptInput }

    private let streamPtr: UnsafeMutablePointer<compression_stream>
    private let dstCapacity = 128 << 10
    private let dstBuffer: UnsafeMutablePointer<UInt8>
    private var finished = false

    public init(_ mode: Mode) throws {
        streamPtr = .allocate(capacity: 1)
        dstBuffer = .allocate(capacity: dstCapacity)
        let op = mode == .compress ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE
        guard compression_stream_init(streamPtr, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            streamPtr.deallocate()
            dstBuffer.deallocate()
            throw Failure.initFailed
        }
    }

    deinit {
        compression_stream_destroy(streamPtr)
        streamPtr.deallocate()
        dstBuffer.deallocate()
    }

    /// Feed one chunk. Pass `final: true` with the last chunk (or with empty
    /// data) to flush; the codec then drains until END. `sink` receives every
    /// produced output block.
    public func process(_ input: Data, final: Bool, sink: (Data) throws -> Void) throws {
        guard !finished else { return }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // src_ptr must be non-nil even for empty input.
            streamPtr.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress
                ?? UnsafePointer(dstBuffer)
            streamPtr.pointee.src_size = raw.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = dstCapacity
                let status = compression_stream_process(streamPtr, flags)
                guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                    throw Failure.corruptInput
                }
                let produced = dstCapacity - streamPtr.pointee.dst_size
                if produced > 0 {
                    try sink(Data(bytes: dstBuffer, count: produced))
                }
                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                // OK with all input consumed and room to spare in dst means
                // the codec wants more input (or, when final, another spin).
                if streamPtr.pointee.src_size == 0 && produced < dstCapacity && !final {
                    return
                }
            }
        }
    }
}
