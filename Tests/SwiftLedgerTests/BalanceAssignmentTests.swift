import Foundation
@testable import SwiftLedger
import Testing

/// A posting that writes a balance assertion and no amount is a balance
/// assignment in hledger: it takes whatever brings the account's running
/// balance to the asserted figure, computed in date order over the whole
/// journal. SwiftLedger used to read the line as an elided amount, and
/// refused the common shape, an assignment beside an elided posting, as two
/// elided amounts. Issue #141. Every expectation here was checked against
/// hledger 1.52.4.
@Suite("balance assignments") struct BalanceAssignmentTests {
    static let opening = """
    2024-01-01 Opening
        Assets:Checking    $10
        Equity:Opening

    """

    static let pay = """
    2024-01-02 Pay
        Assets:Checking    = $15
        Income:Salary

    """

    static func quantities(_ journal: Journal, _ description: String) -> [Decimal] {
        journal.transactions.first { $0.description == description }?.postings.map(\.amount.quantity) ?? []
    }

    @Test
    func `an assignment beside an elided posting takes the difference`() throws {
        let journal = try JournalParser().parse(Self.opening + """
        2024-01-02 Pay
            Assets:Checking    = $15
            Income:Salary

        """)
        #expect(Self.quantities(journal, "Pay") == [5, -5])
        let assigned = try #require(journal.transactions.last?.postings.first)
        #expect(assigned.balanceAssertion == Amount(quantity: 15, commodity: "$", commodityIsPrefix: true))
        #expect(Ledger(journal: journal).checkBalanceAssertions().isEmpty)
    }

    @Test
    func `an assignment sees the entries dated before it, however the file orders them`() throws {
        let journal = try JournalParser().parse("""
        2024-01-05 Statement
            Assets:Checking    = $15
            Income:Salary

        2024-01-01 Opening, written after
            Assets:Checking    $10
            Equity:Opening

        """)
        #expect(Self.quantities(journal, "Statement") == [5, -5])
    }

    @Test
    func `assignment entries written out of date order keep their places in the file`() throws {
        let journal = try JournalParser().parse("""
        2024-01-05 Later
            Assets:Checking    = $15
            Income:Salary

        2024-01-01 Earlier
            Assets:Checking    = $10
            Equity:Opening

        """)
        #expect(journal.transactions.map(\.description) == ["Later", "Earlier"])
        #expect(Self.quantities(journal, "Earlier") == [10, -10])
        #expect(Self.quantities(journal, "Later") == [5, -5])
    }

    @Test
    func `a same-day entry counts only when it is written above`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 A
            Assets:Checking    = $10
            Equity:Opening

        2024-01-01 B
            Assets:Checking    $5
            Equity:Opening

        2024-01-01 C
            Assets:Checking    = $20
            Equity:Opening

        """)
        #expect(Self.quantities(journal, "A") == [10, -10])
        #expect(Self.quantities(journal, "C") == [5, -5])
    }

    @Test
    func `an assignment sees the postings of its own account written above it`() throws {
        let above = try JournalParser().parse("""
        2024-01-02 Pay
            Assets:Checking    $3
            Assets:Checking    = $15
            Income:Salary

        """)
        #expect(Self.quantities(above, "Pay") == [3, 12, -15])

        let below = try JournalParser().parse("""
        2024-01-02 Pay
            Assets:Checking    = $15
            Assets:Checking    $3
            Income:Salary

        """)
        #expect(Self.quantities(below, "Pay") == [15, 3, -18])
    }

    @Test
    func `a posting dated by its comment counts at its own date`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Deposit, cleared on the 5th
            Assets:Checking    $10  ; date:2024-01-05
            Equity:Opening

        2024-01-02 Statement
            Assets:Checking    = $15
            Income:Salary

        """)
        #expect(Self.quantities(journal, "Statement") == [15, -15])
    }

    /// hledger finishes an entry holding an assignment whole, at the entry's
    /// date, so a sibling posting dated by its comment counts there too.
    @Test
    func `a dated posting beside an assignment counts at the entry's date`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Pay
            Assets:Checking    = $15
            Income:Salary  ; date:2024-01-10

        2024-01-05 Salary so far
            Income:Salary    = $-15
            Equity:Adjust

        """)
        #expect(Self.quantities(journal, "Salary so far") == [0, 0])
    }

    @Test
    func `an assignment sees an included file's entries`() throws {
        let files = try JournalFiles([
            "top.journal": "include opening.journal\n\n" + Self.pay,
            "opening.journal": Self.opening,
        ])
        defer { files.remove() }
        #expect(try Self.quantities(files.parse("top.journal"), "Pay") == [5, -5])
    }

    @Test
    func `an assignment in an included file sees the file that includes it`() throws {
        let files = try JournalFiles([
            "top.journal": Self.opening + "include pay.journal\n",
            "pay.journal": Self.pay,
        ])
        defer { files.remove() }
        #expect(try Self.quantities(files.parse("top.journal"), "Pay") == [5, -5])
    }

    @Test
    func `the file is written back as it came`() throws {
        let text = Self.opening + """
        2024-01-02 Pay
            Assets:Checking    = $15
            Income:Salary

        """
        #expect(try JournalSerializer().serialize(JournalParser().parse(text)) == text)
    }

    @Test
    func `an assignment counts as a written amount, so one more posting may elide`() throws {
        let error = #expect(throws: LedgerError.self) {
            try JournalParser().parse("""
            2024-01-01 Opening
                Assets:Checking    = $10
                Assets:Savings
                Equity:Opening

            """)
        }
        #expect(error?.withoutLocation == .multipleElidedPostings)
    }

    @Test
    func `an assignment with nothing to balance against is unbalanced`() throws {
        let error = #expect(throws: LedgerError.self) {
            try JournalParser().parse("2024-01-01 Opening\n    Assets:Checking    = $10\n")
        }
        #expect(error?.withoutLocation == .unbalancedTransaction(commodity: "$", imbalance: 10))
        #expect(error?.line == 1)
    }

    @Test
    func `an assignment on a dated posting is refused, as hledger refuses it`() throws {
        let error = #expect(throws: LedgerError.self) {
            try JournalParser().parse("""
            2024-01-02 Pay
                Assets:Checking    = $15  ; date:2024-01-03
                Income:Salary

            """)
        }
        #expect(error?.line == 2)
        guard case .parseError = error?.withoutLocation else {
            Issue.record("expected a parse error, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `an error finishing an included entry is located at the include line and in the file`() throws {
        let files = try JournalFiles([
            "top.journal": "\ninclude pay.journal\n",
            "pay.journal": "2024-01-02 Pay\n    Assets:Checking    = $15\n",
        ])
        defer { files.remove() }
        let error = #expect(throws: LedgerError.self) { try files.parse("top.journal") }
        #expect(error?.line == 2)
        guard case let .inJournal(_, _, .inIncludedFile(path, .inJournal(line, entry, underlying))) = error else {
            Issue.record("expected a doubly located error, got \(String(describing: error))")
            return
        }
        #expect(path == files.url("pay.journal").path)
        #expect(line == 1)
        #expect(entry == "2024-01-02 Pay")
        #expect(underlying == .unbalancedTransaction(commodity: "$", imbalance: 15))
    }
}
