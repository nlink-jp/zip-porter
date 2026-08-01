import XCTest
@testable import ZipPorterCore

final class CRC32Tests: XCTestCase {
    func testKnownVectors() {
        // Standard CRC-32 check value for "123456789".
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }

    func testStreamingMatchesOneShot() {
        let payload = Data((0..<10_000).map { UInt8($0 % 256) })
        var crc = CRC32()
        for chunk in stride(from: 0, to: payload.count, by: 777) {
            crc.update(payload.subdata(in: chunk..<min(chunk + 777, payload.count)))
        }
        XCTAssertEqual(crc.value, CRC32.checksum(payload))
    }
}

final class DOSDateTimeTests: XCTestCase {
    func testRoundTripEvenSecond() throws {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 8, 1, 14, 30, 22)
        let date = try XCTUnwrap(Calendar.current.date(from: c))
        let dos = DOSDateTime.from(date)
        XCTAssertEqual(DOSDateTime.toDate(date: dos.date, time: dos.time), date)
    }

    func testOddSecondsTruncateToTwoSecondResolution() throws {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 8, 1, 14, 30, 23)
        let date = try XCTUnwrap(Calendar.current.date(from: c))
        let dos = DOSDateTime.from(date)
        let restored = try XCTUnwrap(DOSDateTime.toDate(date: dos.date, time: dos.time))
        XCTAssertEqual(restored, date.addingTimeInterval(-1))
    }

    func testPre1980Clamps() {
        let dos = DOSDateTime.from(Date(timeIntervalSince1970: 0)) // 1970
        XCTAssertEqual(Int(dos.date >> 9) + 1980, 1980)
    }
}

final class BinaryHelperTests: XCTestCase {
    func testLittleEndianRoundTrip() {
        var d = Data()
        d.appendU16(0xBEEF)
        d.appendU32(0xDEAD_BEEF)
        d.appendU64(0x0123_4567_89AB_CDEF)
        XCTAssertEqual(d.readU16(at: 0), 0xBEEF)
        XCTAssertEqual(d.readU32(at: 2), 0xDEAD_BEEF)
        XCTAssertEqual(d.readU64(at: 6), 0x0123_4567_89AB_CDEF)
    }

    func testReadsRespectSlicing() {
        // Data slices keep their parent's indices; readers must use startIndex.
        var d = Data([0xAA, 0xAA, 0x34, 0x12])
        d = d.subdata(in: 2..<4) // fresh Data
        let sliced = Data([0xAA, 0xAA, 0x34, 0x12])[2...]
        XCTAssertEqual(d.readU16(at: 0), 0x1234)
        XCTAssertEqual(sliced.readU16(at: 0), 0x1234)
    }
}
