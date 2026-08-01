import Foundation

/// MS-DOS date/time as stored in ZIP headers: local time, 2-second
/// resolution, epoch 1980. Values outside 1980...2107 are clamped.
public enum DOSDateTime {
    public static func from(_ date: Date, calendar: Calendar = .current) -> (date: UInt16, time: UInt16) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let dosDate = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) >> 1)
        return (dosDate, dosTime)
    }

    public static func toDate(date: UInt16, time: UInt16, calendar: Calendar = .current) -> Date? {
        var c = DateComponents()
        c.year = Int(date >> 9) + 1980
        c.month = Int((date >> 5) & 0x0F)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        return calendar.date(from: c)
    }
}
