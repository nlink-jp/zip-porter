import Foundation

/// Streaming CRC-32 (IEEE 802.3, the ZIP/zlib polynomial 0xEDB88320).
public struct CRC32: Sendable {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                state = Self.table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
            }
        }
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    /// One-shot convenience.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}
