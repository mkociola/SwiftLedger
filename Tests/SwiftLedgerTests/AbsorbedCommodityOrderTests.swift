import Foundation
@testable import SwiftLedger
import Testing

/// An elided line that absorbs several commodities becomes one posting per
/// commodity, and hledger lists those postings sorted by commodity symbol, by
/// Unicode code point, whatever order the entry wrote them in. Reading them in
/// that order is what makes a rebuilt entry the one hledger would print.
@Suite("absorbed commodity order") struct AbsorbedCommodityOrderTests {
    /// The written amounts come euro sign, dollar, `EUR`, and hledger 1.52.4
    /// prints the absorbed postings `$`, `EUR`, `€`.
    @Test
    func `the absorbed postings are sorted by commodity symbol`() throws {
        let text = """
        2024-01-01 Opening balances
            Expenses:Rent      €10.00
            Expenses:Rent      $20.00
            Expenses:Rent      30.00 EUR
            Assets:Checking
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let absorbed = transaction.postings.filter { $0.accountName == "Assets:Checking" }
        #expect(absorbed.map(\.amount) == [
            Amount(quantity: -20, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -30, commodity: "EUR", commodityIsPrefix: false),
            Amount(quantity: -10, commodity: "€", commodityIsPrefix: true),
        ])
    }

    /// The order is code point order rather than a locale's: every capital
    /// letter comes before every small one, and `£` comes after all of ASCII,
    /// which is where hledger puts them.
    @Test
    func `the sort is by code point rather than by locale`() throws {
        let text = """
        2024-01-01 Opening balances
            Expenses:Rent      £1.00
            Expenses:Rent      2.00 eur
            Expenses:Rent      3.00 Zl
            Expenses:Rent      $4.00
            Assets:Checking
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let absorbed = transaction.postings.filter { $0.accountName == "Assets:Checking" }
        #expect(absorbed.map(\.amount.commodity) == ["$", "Zl", "eur", "£"])
    }

    /// The entry nobody edited is written back from its own lines, so the
    /// elided line stays one line. Rebuilt, it is written one line per
    /// commodity in the sorted order, which is how hledger prints it.
    @Test
    func `a rebuilt entry writes the absorbed lines in sorted order`() throws {
        let text = """
        2024-01-01 Opening balances
            Expenses:Rent      €10.00
            Expenses:Rent      $20.00
            Assets:Checking
        """
        var journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)

        let parsed = try #require(journal.transactions.first)
        let rebuilt = try Transaction(
            date: parsed.date, description: parsed.description, postings: parsed.postings,
        )
        let removed = journal.remove(.transaction(parsed))
        #expect(removed)
        journal.append(.transaction(rebuilt))

        let checking = JournalSerializer().serialize(journal)
            .components(separatedBy: "\n")
            .filter { $0.contains("Assets:Checking") }
        #expect(checking == ["    Assets:Checking    -$20.00", "    Assets:Checking    -€10.00"])
    }
}
