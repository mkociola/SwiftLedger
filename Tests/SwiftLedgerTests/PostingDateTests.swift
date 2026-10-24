import Foundation
@testable import SwiftLedger
import Testing

/// A posting's comments can give it a date of its own, with a `date:` or
/// `date2:` tag or ledger's `[date=date2]` brackets. Every case here was run
/// through hledger 1.52.4 first. Issue #43.
@Suite("posting dates") struct PostingDateTests {
    /// The second posting of a one-entry journal dated 2024-01-31, with
    /// `comment` after it, as `(date, date2)`.
    private static func dates(_ comment: String, header: String = "2024-01-31 Rent") throws -> [String?] {
        let journal = try JournalParser().parse(
            "\(header)\n    Expenses:Rent      $10\n    Assets:Checking  \(comment)",
        )
        let posting = try #require(journal.transactions.first?.postings.last)
        return [posting.date?.description, posting.date2?.description]
    }

    struct Case: CustomTestStringConvertible {
        var comment: String
        var date: String?
        var date2: String?
        var header = "2024-01-31 Rent"

        var testDescription: String {
            comment
        }
    }

    static let readable: [Case] = [
        Case(comment: "; date:2024-02-02", date: "2024-02-02"),
        Case(comment: ";date:2024-02-02", date: "2024-02-02"),
        Case(comment: "; date: 2024/02/02", date: "2024-02-02"),
        Case(comment: "; date:\t2024.02.02", date: "2024-02-02"),
        // The value runs to a comma, and only its leading date is read.
        Case(comment: "; date:2024-02-02 cleared late, other:1", date: "2024-02-02"),
        Case(comment: "; date:2024-02-02x", date: "2024-02-02"),
        // A short date takes the entry's year, whatever month it names.
        Case(comment: "; date:02-02", date: "2024-02-02"),
        Case(comment: "; date:01-02", date: "2024-01-02", header: "2024-12-31 Rent"),
        Case(comment: "; note text date:2024-02-02", date: "2024-02-02"),
        Case(comment: "; foo:bar, date:2024-02-02", date: "2024-02-02"),
        Case(comment: "; : date:2024-02-02", date: "2024-02-02"),
        Case(comment: "; date:2024-02-02, date2:2024-02-05", date: "2024-02-02", date2: "2024-02-05"),
        Case(comment: "; date2:2024-02-05", date2: "2024-02-05"),
        // The first date in the text wins, bracket or tag.
        Case(comment: "; date:2024-02-02, date:2024-02-03", date: "2024-02-02"),
        Case(comment: "; date:2024-02-02 [2024-02-03]", date: "2024-02-02"),
        Case(comment: "; [2024-02-03] date:2024-02-02", date: "2024-02-03"),
        Case(comment: "; [=2024-03-01] date2:2024-04-01", date2: "2024-03-01"),
        Case(comment: "; [2024-02-02]", date: "2024-02-02"),
        Case(comment: "; cleared [02/02] late", date: "2024-02-02"),
        Case(comment: "; [=02-05]", date2: "2024-02-05"),
        // A short secondary date takes the primary date's year.
        Case(comment: "; [2023-02-02=03-01]", date: "2023-02-02", date2: "2023-03-01"),
        Case(comment: "; a:[2024-02-02], b:1", date: "2024-02-02"),
        // None of these is a date: the value of `other` runs to the end, a
        // tag name is the whole word before the colon, names are case
        // sensitive, and a bracket needs a digit and a separator.
        Case(comment: "; other:1 date:2024-02-02"),
        Case(comment: "; x,date:2024-02-02"),
        Case(comment: "; (date:2024-02-02)"),
        Case(comment: "; Date:2024-02-02"),
        Case(comment: "; xdate:2024-02-02"),
        Case(comment: "; [note]"),
        Case(comment: "; [2024]"),
        Case(comment: "; [-]"),
        Case(comment: "; [2024-02-02 x]"),
        Case(comment: "; [2024-02-02"),
    ]

    @Test(arguments: readable)
    func `a comment's date is read as hledger reads it`(entry: Case) throws {
        #expect(try Self.dates(entry.comment, header: entry.header) == [entry.date, entry.date2])
    }

    /// Comments hledger refuses the file over: a `date:` or `date2:` value,
    /// or a bracket that looks like a date, that is not one.
    @Test(arguments: [
        "; date:", "; date:notadate", "; date:2024-02-30", "; date:24-02-02", "; date:2024-02/02",
        "; date2:", "; date2:xx", "; [2024-13-45]", "; [1/2=]", "; [2024-02-02-03]", "; [1-2-3]",
        "; [2024-02/02]",
    ])
    func `a date that is not one refuses the file`(comment: String) {
        #expect(throws: LedgerError.self) { try Self.dates(comment) }
    }

    @Test
    func `a date on a comment line below the posting counts, after the inline one`() throws {
        let journal = try JournalParser().parse("""
        2024-01-31 Rent
            Expenses:Rent      $10
            ; date:2024-02-09
            Assets:Checking  ; date:2024-02-02
            ; date:2024-02-03, date2:2024-02-04
        """)
        let postings = try #require(journal.transactions.first?.postings)
        #expect(postings[0].date?.description == "2024-02-09")
        #expect(postings[1].date?.description == "2024-02-02")
        #expect(postings[1].date2?.description == "2024-02-04")
    }

    /// An elided line that absorbs two commodities becomes two postings, the
    /// inline comment on the first and the comment lines on the last, and
    /// hledger dates the whole line, so both are dated.
    @Test
    func `every posting an elided line splits into takes the line's dates`() throws {
        let journal = try JournalParser().parse("""
        2024-01-31 Rent
            Expenses:Rent      $10
            Expenses:Rent      10 EUR
            Assets:Checking  ; date:2024-02-02
            ; date2:2024-02-09
        """)
        let legs = try #require(journal.transactions.first?.postings.dropFirst(2))
        #expect(legs.map(\.amount.commodity) == ["$", "EUR"])
        #expect(legs.map { $0.date?.description } == ["2024-02-02", "2024-02-02"])
        #expect(legs.map { $0.date2?.description } == ["2024-02-09", "2024-02-09"])
    }

    @Test
    func `the comment is kept as written`() throws {
        let text = "2024-01-31 Rent\n    Expenses:Rent      $10\n    Assets:Checking  ; date:02-02"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.last?.comment == "date:02-02")
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a transaction built in code reads its postings' dates too`() throws {
        let transaction = try Transaction(
            date: JournalDate(year: 2024, month: 12, day: 31),
            description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Rent", amount: Amount(quantity: 10, commodity: "$")),
                Posting(
                    accountName: "Assets:Checking", amount: Amount(quantity: -10, commodity: "$"),
                    comment: "date:01-02",
                ),
            ],
        )
        #expect(transaction.postings[0].date == nil)
        #expect(try transaction.postings[1].date == JournalDate(year: 2024, month: 1, day: 2))
    }

    @Test
    func `a date that is not one refuses a transaction built in code`() {
        #expect(throws: LedgerError.self) {
            try Transaction(
                date: JournalDate(year: 2024, month: 1, day: 31),
                description: "Rent",
                postings: [Posting(
                    accountName: "Assets:Checking", amount: Amount(quantity: 0, commodity: "$"),
                    comment: "date:soon",
                )],
            )
        }
    }

    /// The split elided line above, whose second leg has no comment of its
    /// own to read a date from.
    private static let splitLine = "2024-01-31 Rent\n    Expenses:Rent      $10\n    Expenses:Rent      10 EUR\n"
        + "    Assets:Checking  ; date:2024-02-02\n    ; date2:2024-02-09"

    @Test
    func `the dates round trip through JSON, a split line's legs included`() throws {
        let transaction = try #require(JournalParser().parse(Self.splitLine).transactions.first)
        let decoded = try JSONDecoder().decode(Transaction.self, from: JSONEncoder().encode(transaction))
        #expect(decoded.postings.map(\.date) == transaction.postings.map(\.date))
        #expect(decoded == transaction)
    }

    /// A rebuilt entry writes each leg of a split line on a line of its own,
    /// and a leg whose comments do not write its dates gets them written.
    @Test
    func `a rebuilt split line keeps every leg's dates`() throws {
        let parsed = try #require(JournalParser().parse(Self.splitLine).transactions.first)
        let rebuilt = try Transaction(date: parsed.date, description: parsed.description, postings: parsed.postings)
        let text = JournalSerializer().serialize(Journal(items: [.transaction(rebuilt)]))
        #expect(text.contains("10 EUR  ; date:2024-02-02\n"))
        let reread = try #require(JournalParser().parse(text).transactions.first)
        #expect(reread.postings.map(\.date) == parsed.postings.map(\.date))
        #expect(reread.postings.map(\.date2) == parsed.postings.map(\.date2))
    }

    @Test
    func `a rebuilt leg with an empty comment gets the tag without a stray comma`() throws {
        let text = "2024-01-31 Rent\n    Expenses:Rent      $10\n    Expenses:Rent      10 EUR\n"
            + "    Assets:Checking  ;\n    ; date2:2024-02-09"
        let parsed = try #require(JournalParser().parse(text).transactions.first)
        let rebuilt = try Transaction(date: parsed.date, description: parsed.description, postings: parsed.postings)
        let written = JournalSerializer().serialize(Journal(items: [.transaction(rebuilt)]))
        #expect(written.contains("-$10.00  ; date2:2024-02-09\n"))
    }
}
