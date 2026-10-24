import Foundation
@testable import SwiftLedger
import Testing

/// Every query bounded by dates counts a posting on its own date when its
/// comment gives it one, as hledger 1.52.4 does, and every transaction query
/// keeps the transaction's date. Issue #43.
@Suite("posting dates in queries") struct PostingDateQueryTests {
    /// The rent leaves the account on the 2nd, after the coffee on the 1st,
    /// and the refund is income on February 3rd though booked in March.
    private static let ledger: Ledger = {
        let journal = try? JournalParser().parse("""
        2024-01-01 Opening
            Assets:Checking    $5000.00
            Equity:Opening

        2024-01-31 Rent, cleared on the 2nd
            Expenses:Rent      $1200.00
            Assets:Checking  ; date:2024-02-02

        2024-02-01 Coffee
            Expenses:Food         $5.00
            Assets:Checking

        2024-03-01 Refund, booked on the 3rd of February
            Assets:Checking      $50.00  ; date:2024-02-03
            Income:Refunds  ; date:2024-02-03
        """)
        return Ledger(journal: journal ?? Journal())
    }()

    private static func day(_ month: Int, _ day: Int) throws -> JournalDate {
        try JournalDate(year: 2024, month: month, day: day)
    }

    @Test
    func `a balance as of a day leaves out a posting dated later`() throws {
        let ledger = Self.ledger
        #expect(try ledger.balance(for: "Assets:Checking", asOf: Self.day(1, 31)).map(\.quantity) == [5000])
        #expect(try ledger.balance(for: "Assets:Checking", asOf: Self.day(2, 2)).map(\.quantity) == [3795])
        #expect(try ledger.subtreeBalance(forPrefix: "Assets", asOf: Self.day(2, 1)).map(\.quantity) == [4995])
        #expect(try ledger.allBalances(asOf: Self.day(1, 31))["Assets:Checking"]?.map(\.quantity) == [5000])
        let sheet = try BalanceSheet(ledger: ledger, asOf: Self.day(1, 31))
        #expect(sheet.assets.first?.amounts.map(\.quantity) == [5000])
    }

    @Test
    func `the daily series moves on the posting's own day`() throws {
        let series = try Self.ledger.subtreeBalanceSeries(
            forPrefix: "Assets", from: Self.day(1, 30), to: Self.day(2, 3),
        )
        #expect(series.map { $0.map(\.quantity) } == [[5000], [5000], [4995], [3795], [3845]])
    }

    @Test
    func `periods bucket a posting by its own date`() throws {
        let starts = try [Self.day(1, 1), Self.day(2, 1)]
        let income = try Self.ledger.incomeStatementSeries(bucketStarts: starts, to: Self.day(2, 29))
        #expect(income.map { $0.revenues.map(\.quantity) } == [[], [-50]])
        #expect(income.map { $0.expenses.map(\.quantity) } == [[1200], [5]])

        let matrix = try Self.ledger.balanceMatrix(bucketStarts: [Self.day(2, 1)], to: Self.day(2, 29))
        #expect(matrix["Assets:Checking"]?.opening.map(\.quantity) == [5000])
        #expect(matrix["Assets:Checking"]?.changes.map { $0.map(\.quantity) } == [[-1155]])
        #expect(matrix["Income:Refunds"]?.changes.map { $0.map(\.quantity) } == [[-50]])
    }

    @Test
    func `a statement lists postings in the order of their own dates`() throws {
        let statement = AccountStatement(ledger: Self.ledger, accountName: "Assets:Checking")
        #expect(statement.lines.map(\.transaction.description) == [
            "Opening", "Coffee", "Rent, cleared on the 2nd", "Refund, booked on the 3rd of February",
        ])
        #expect(statement.lines.map { $0.runningBalance.map(\.quantity) } == [[5000], [4995], [3795], [3845]])

        let february = try AccountStatement(
            ledger: Self.ledger, accountName: "Assets:Checking", from: Self.day(2, 1), to: Self.day(2, 29),
        )
        #expect(february.lines.map(\.posting.amount.quantity) == [-5, -1200, 50])

        let january = try AccountStatement(
            ledger: Self.ledger, accountName: "Assets:Checking", from: Self.day(1, 1), to: Self.day(1, 31),
        )
        #expect(january.lines.map(\.posting.amount.quantity) == [5000])
    }

    @Test
    func `an income statement counts a posting in its own period`() throws {
        let statement = try IncomeStatement(ledger: Self.ledger, from: Self.day(2, 1), to: Self.day(2, 29))
        #expect(statement.revenues.map(\.account.name) == ["Income:Refunds"])
        #expect(statement.expenses.map(\.account.name) == ["Expenses:Food"])
    }

    @Test
    func `a transaction query keeps the transaction's date`() throws {
        let february = try Self.ledger.transactions(from: Self.day(2, 1), to: Self.day(2, 29))
        #expect(february.map(\.description) == ["Coffee"])
    }

    /// Assertions are replayed by posting date, within one entry too.
    @Test(arguments: [
        "2024-01-01 a\n    A    $10  ; date:2024-01-05\n    B\n\n2024-01-02 b\n    A    $0 = $0\n    B",
        "2024-01-01 a\n    A    $10  ; date:2024-01-05\n    A    $5 = $5\n    B",
    ])
    func `an assertion sees the postings dated before it`(text: String) throws {
        #expect(try Ledger(journal: JournalParser().parse(text)).checkBalanceAssertions().isEmpty)
    }

    @Test
    func `an assertion leaves out a posting dated after it`() throws {
        let text = "2024-01-01 a\n    A    $10  ; date:2024-01-05\n    B\n\n2024-01-02 b\n    A    $5 = $15\n    B"
        let failures = try Ledger(journal: JournalParser().parse(text)).checkBalanceAssertions()
        #expect(failures.map(\.actual.quantity) == [5])
    }
}
