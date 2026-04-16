import Foundation

/// A calendar date (year, month, day) with no time or timezone component.
///
/// Used for all transaction dates in plain-text accounting files, avoiding the
/// timezone-related off-by-one-day bugs that `Foundation.Date` introduces.
public struct JournalDate: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard year > 0,
              (1 ... 12).contains(month),
              (1 ... 31).contains(day)
        else {
            throw LedgerError.invalidDate(String(format: "%04d-%02d-%02d", year, month, day))
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Creates a `JournalDate` from a `Foundation.Date` in the given calendar.
    public init(_ date: Date, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day else {
            preconditionFailure("Calendar failed to extract year/month/day from date")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Today's date using the current calendar.
    public static var today: JournalDate {
        JournalDate(Date())
    }

    /// Returns a `Foundation.Date` at midnight in the given timezone.
    public func date(timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let result = cal.date(from: components) else {
            preconditionFailure("Calendar failed to construct date from \(self)")
        }
        return result
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: JournalDate, rhs: JournalDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}
