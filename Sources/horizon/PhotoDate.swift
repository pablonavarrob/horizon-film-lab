import Foundation

/// Stores only the calendar components the photographer knows. A Date anchors
/// the picker internally; its unspecified month/day are never written to metadata.
enum PhotoDate {
    enum Precision: String, CaseIterable { case day, month, year }

    struct Selection {
        let date: Date
        let precision: Precision
    }

    static func calendar(in timeZone: TimeZone = .current) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        return result
    }

    static func parse(_ text: String, in timeZone: TimeZone = .current) -> Date? {
        guard let selection = parseSelection(text, in: timeZone),
              selection.precision == .day else { return nil }
        return selection.date
    }

    static func parseSelection(_ text: String, in timeZone: TimeZone = .current) -> Selection? {
        let bytes = Array(text.utf8)
        let precision: Precision
        switch bytes.count {
        case 4: precision = .year
        case 7: precision = .month
        case 10: precision = .day
        default: return nil
        }
        guard bytes.enumerated().allSatisfy({ index, byte in
                  (index == 4 || index == 7) ? byte == 45 : (48...57).contains(byte)
              }),
              let year = Int(text.prefix(4)),
              (1...9999).contains(year) else { return nil }
        let month = bytes.count >= 7 ? Int(text.dropFirst(5).prefix(2))! : 1
        let day = bytes.count == 10 ? Int(text.suffix(2))! : 1
        let cal = calendar(in: timeZone)
        guard let date = cal.date(from: DateComponents(year: year, month: month,
                                                       day: day, hour: 12)) else { return nil }
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return Selection(date: date, precision: precision)
    }

    static func serialize(_ date: Date, precision: Precision = .day,
                          in timeZone: TimeZone = .current) -> String {
        let parts = calendar(in: timeZone).dateComponents([.year, .month, .day], from: date)
        switch precision {
        case .year:
            return String(format: "%04d", parts.year ?? 0)
        case .month:
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        case .day:
            return String(format: "%04d-%02d-%02d", parts.year ?? 0,
                          parts.month ?? 0, parts.day ?? 0)
        }
    }
}
