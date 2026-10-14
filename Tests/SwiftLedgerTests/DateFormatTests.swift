import Foundation
@testable import SwiftLedger
import Testing

/// The parser recognised a date only as the ten characters `YYYY-MM-DD` or
/// `YYYY/MM/DD`, so an entry dated `2024/1/5` or `2024.01.06`, or `01/15`
/// under a `Y 2024` line, was kept as a directive with its postings and left
/// out of every balance without a word, and a secondary date without a year
/// refused the file (issue #36). Every case below was read by hledger 1.52.4
/// first, and is read here the way it reads it.
@Suite("date formats") struct DateFormatTests {
    private static let postings = "\n    Expenses:Utilities    $1.00\n    Assets:Checking\n"

    /// A file and the date of the entry it ends on.
    struct Case: CustomTestStringConvertible {
        let text: String
        let date: JournalDate
        var auxDate: JournalDate?
        var testDescription: String {
            text
        }

        static let list: [Case] = [
            Case(text: "2024/1/5 x", date: date(2024, 1, 5)),
            Case(text: "2024.01.06 x", date: date(2024, 1, 6)),
            Case(text: "2024-1-5 x", date: date(2024, 1, 5)),
            Case(text: "2024-001-0005 x", date: date(2024, 1, 5)),
            Case(text: "20245-01-05 x", date: date(20245, 1, 5)),
            Case(text: "2024-02-29 x", date: date(2024, 2, 29)),
            Case(text: "2024-01-08", date: date(2024, 1, 8)),
            Case(text: "2024-01-08\tx", date: date(2024, 1, 8)),
            Case(text: "Y 2024\n\n01/15 x", date: date(2024, 1, 15)),
            Case(text: "year 2024\n1.5 x", date: date(2024, 1, 5)),
            Case(text: "Y2024\n1-5 x", date: date(2024, 1, 5)),
            Case(text: "Y\t2024  ; the year\n1/5 x", date: date(2024, 1, 5)),
            Case(text: "Y 2024 # the year\n1/5 x", date: date(2024, 1, 5)),
            Case(text: "Y 2024\n01/15 x\nY 2025\n01/15 x", date: date(2025, 1, 15)),
            Case(text: "Y 2024\n2023-01-15 x", date: date(2023, 1, 15)),
            Case(text: "2024-01-08=01-10 x", date: date(2024, 1, 8), auxDate: date(2024, 1, 10)),
            Case(text: "2024/01/08=1.10 x", date: date(2024, 1, 8), auxDate: date(2024, 1, 10)),
            Case(text: "2024-01-08=2025/1/10 x", date: date(2024, 1, 8), auxDate: date(2025, 1, 10)),
            Case(text: "Y 2020\n2024-01-08=01-10 x", date: date(2024, 1, 8), auxDate: date(2024, 1, 10)),
            Case(text: "Y 2024\n01/15=01/20 x", date: date(2024, 1, 15), auxDate: date(2024, 1, 20)),
        ]

        private static func date(_ year: Int, _ month: Int, _ day: Int) -> JournalDate {
            // swiftlint:disable:next force_try
            try! JournalDate(year: year, month: month, day: day)
        }
    }

    @Test(arguments: Case.list)
    func `a date hledger reads is read the same way`(entry: Case) throws {
        let text = entry.text + Self.postings
        let journal = try JournalParser().parse(text)
        let transaction = try #require(journal.transactions.last)
        #expect(transaction.date == entry.date)
        #expect(transaction.auxDate == entry.auxDate)
        #expect(!journal.directives.contains { $0.hasSuffix(" x") })
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Without a `Y` line a date that leaves out its year is in the current
    /// year, which is how hledger reads it.
    @Test
    func `a date without a year and no Y line is in the current year`() throws {
        let journal = try JournalParser().parse("01/15 x" + Self.postings)
        #expect(try journal.transactions.first?.date == JournalDate(year: JournalDate.today.year, month: 1, day: 15))
    }

    /// Each one is a file hledger refuses, and each refuses here at the line
    /// of the date.
    @Test(arguments: [
        "2024-13-01 x", "2024-02-30 x", "2023-02-29 x", "2024-1-32 x", "2024-00-05 x", "2024-01-00 x",
        "2024-01/05 x", "2024/01.05 x", "24-01-05 x", "4-01-05 x", "2024-01 x", "2024x x", "12 x",
        "2024-01-08x", "2024-01-08* x", "2024-01-08- x", "2024-01-08=02-30 x", "2024-01-08=01-10x",
        "1/2/3 x", "2024-01-0٥ x", "2024-01-99999999999999999999 x", "2024-01-01;paid early",
        "2024-01-01=2024-01-02;note",
    ])
    func `a date hledger refuses is refused at its line`(header: String) {
        expectRefused("; header\n" + header + Self.postings, atLine: 2)
    }

    /// The calendar check lives in `JournalDate` itself, so a date built in
    /// code is held to it as much as one the parser reads.
    @Test
    func `a day the calendar does not have is no date`() throws {
        #expect(throws: LedgerError.invalidDate("2024-02-30")) { try JournalDate(year: 2024, month: 2, day: 30) }
        #expect(throws: LedgerError.invalidDate("1900-02-29")) { try JournalDate(year: 1900, month: 2, day: 29) }
        #expect(throws: LedgerError.invalidDate("2024-04-31")) { try JournalDate(year: 2024, month: 4, day: 31) }
        #expect(try JournalDate(year: 2000, month: 2, day: 29).day == 29)
    }

    @Test
    func `a short date is checked against the year it is given`() {
        expectRefused("Y 2023\n02/29 x" + Self.postings, atLine: 2)
    }

    /// A `Y` or `year` line hledger cannot read a year of four digits or more
    /// from refuses the file at its line, as it does in hledger.
    @Test(arguments: ["Y 24", "Y", "Y abc", "Y 2024x", "Y 2024 extra", "year 24", "Year 2024", "yearly 2024"])
    func `a year directive hledger cannot read is refused`(directive: String) {
        expectRefused("; header\n" + directive + "\n2024-01-05 x" + Self.postings, atLine: 2) { error in
            if case .unreadableDirective = error { return true }
            return false
        }
    }

    /// The directive is kept verbatim, as every directive is, and the year
    /// it sets lives in the parser while it reads the file.
    @Test
    func `a year directive is kept verbatim`() throws {
        let journal = try JournalParser().parse("Y 2024 ; the year\n01/15 x" + Self.postings)
        #expect(journal.directives == ["Y 2024 ; the year"])
    }

    /// A rebuilt entry is written with the date in the one form the
    /// serializer writes, while an untouched one keeps its own spelling.
    @Test
    func `a rebuilt entry writes its dates in full`() throws {
        let journal = try JournalParser().parse("Y 2024\n1/5=1/9 x" + Self.postings)
        let entry = try #require(journal.transactions.first)
        let rebuilt = try Transaction(
            date: entry.date, auxDate: entry.auxDate, description: entry.description, postings: entry.postings,
        )
        let text = JournalSerializer().serialize(Journal(items: [.transaction(rebuilt)]))
        #expect(text.hasPrefix("2024-01-05=2024-01-09 x\n"))
    }

    private func expectRefused(
        _ text: String, atLine line: Int, matching: (LedgerError) -> Bool = { _ in true },
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        #expect(sourceLocation: sourceLocation) {
            try JournalParser().parse(text)
        } throws: { error in
            guard let error = error as? LedgerError, error.line == line else { return false }
            return matching(error.withoutLocation)
        }
    }
}
