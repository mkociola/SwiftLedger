import Foundation
@testable import SwiftLedger
import Testing

/// hledger reads an included file under the `alias`, `apply account`, `Y`,
/// `D`, `commodity` and `decimal-mark` lines in force at the `include` line,
/// and drops what the included file declares when it returns to the
/// including one. Each file keeps its own layout. Checked against hledger
/// 1.52.4 (issue #45).
@Suite("an included file reads under the declarations in force") struct IncludeScopeTests {
    static func read(_ top: String, _ part: String) throws -> Journal {
        let files = try JournalFiles(["top.journal": top, "part.journal": part])
        defer { files.remove() }
        return try files.parse("top.journal")
    }

    static func entry(_ journal: Journal, _ description: String) throws -> Transaction {
        try #require(journal.transactions.first { $0.description == description })
    }

    static func posting(_ journal: Journal, _ description: String) throws -> Posting {
        try #require(entry(journal, description).postings.first)
    }

    @Test
    func `an alias applies inside the included file`() throws {
        let journal = try Self.read(
            "alias chk = Assets:Checking\ninclude part.journal\n",
            "2024-01-01 Rent\n    Expenses:Rent  $5.00\n    chk\n",
        )
        #expect(Ledger(journal: journal).balance(for: "Assets:Checking").map(\.quantity) == [-5])
    }

    @Test
    func `apply account applies inside the included file`() throws {
        let journal = try Self.read("apply account Top\ninclude part.journal\n", "2024-01-01 In\n    a  1\n    b\n")
        #expect(try Self.posting(journal, "In").accountName == "Top:a")
    }

    @Test
    func `a year applies inside the included file`() throws {
        let journal = try Self.read("Y 2020\ninclude part.journal\n", "01-02 In\n    a  1\n    b\n")
        #expect(try Self.entry(journal, "In").date == JournalDate(year: 2020, month: 1, day: 2))
    }

    @Test
    func `a decimal mark applies inside the included file`() throws {
        let journal = try Self.read("decimal-mark ,\ninclude part.journal\n", "2024-01-01 In\n    a  2,5 EUR\n    b\n")
        #expect(try Self.posting(journal, "In").amount.quantity == Decimal(string: "2.5"))
    }

    @Test
    func `a commodity applies inside the included file`() throws {
        let journal = try Self.read(
            "commodity 1.000,00 EUR\ninclude part.journal\n", "2024-01-01 In\n    a  1.500 EUR\n    b\n",
        )
        #expect(try Self.posting(journal, "In").amount.quantity == 1500)
    }

    @Test
    func `a default commodity applies inside the included file`() throws {
        let journal = try Self.read("D 1.000,00 EUR\ninclude part.journal\n", "2024-01-01 In\n    a  7\n    b\n")
        let amount = try Self.posting(journal, "In").amount
        #expect(amount.quantity == 7)
        #expect(amount.commodity == "EUR")
    }

    @Test
    func `an included file's declarations do not leak back`() throws {
        let files = try JournalFiles([
            "top.journal": """
            decimal-mark ,
            Y 2024
            include part.journal
            include sibling.journal

            01-03 After
                x  1,5
                Assets:Checking  8
                Equity:Opening

            """,
            "part.journal": """
            alias x = Child:X
            Y 2030
            apply account Kid
            D 1000,00 EUR
            decimal-mark .

            01-04 Late
                x  3.5
                y

            """,
            "sibling.journal": "01-05 Sibling\n    x  4,5\n    Assets:Checking\n",
        ])
        defer { files.remove() }
        let journal = try files.parse("top.journal")
        let after = try #require(journal.transactions.first { $0.description == "After" })
        #expect(try after.date == JournalDate(year: 2024, month: 1, day: 3))
        #expect(after.postings.map(\.accountName) == ["x", "Assets:Checking", "Equity:Opening"])
        #expect(after.postings.first?.amount.quantity == Decimal(string: "1.5"))
        #expect(after.postings[1].amount.commodity.isEmpty)
        let sibling = try Self.posting(journal, "Sibling")
        #expect(sibling.accountName == "x")
        #expect(sibling.amount.quantity == Decimal(string: "4.5"))
        let late = try Self.posting(journal, "Late")
        #expect(try Self.entry(journal, "Late").date == JournalDate(year: 2030, month: 1, day: 4))
        #expect(late.accountName == "Kid:x")
        #expect(try late.amount == Amount(quantity: #require(Decimal(string: "3.5")), commodity: "EUR"))
    }

    @Test
    func `end apply account in an included file closes the prefix there only`() throws {
        let journal = try Self.read(
            "apply account Top\ninclude part.journal\n2024-01-09 Back\n    a  1\n    b\n",
            "2024-01-08 In\n    a  1\n    b\nend apply account\n2024-01-08 In2\n    a  1\n    b\n",
        )
        #expect(try Self.posting(journal, "In").accountName == "Top:a")
        #expect(try Self.posting(journal, "In2").accountName == "a")
        #expect(try Self.posting(journal, "Back").accountName == "Top:a")
    }

    @Test
    func `an included file's layout is its own`() throws {
        let journal = try Self.read(
            "include part.journal\n\n2024-01-02 Top\n  Expenses:Rent  $1.00\n  Assets:Checking\n",
            "2024-01-01 Part\r\n\tExpenses:Rent  $1.00\r\n\tAssets:Checking\r\n",
        )
        guard case let .include(included) = journal.items.first, let part = included.journals.first else {
            Issue.record("expected an include item")
            return
        }
        #expect(part.postingIndent == "\t")
        #expect(part.lineEnding == .windows)
        #expect(journal.postingIndent == "  ")
        #expect(journal.lineEnding == .unix)
    }
}
