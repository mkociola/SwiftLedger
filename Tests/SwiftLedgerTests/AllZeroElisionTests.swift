import Foundation
@testable import SwiftLedger
import Testing

/// An elided line whose group already nets to zero in every commodity has
/// nothing to absorb, and hledger still gives it a zero in each of those
/// commodities, sorted by symbol, rather than a single zero in the first one
/// written. A group that leaves something over in one commodity drops the
/// ones that net out, and both tools agree on that already.
@Suite("all-zero elision") struct AllZeroElisionTests {
    /// The entry writes euros before dollars, and hledger 1.52.4 prints the
    /// elided line as `$0` then `0 EUR`.
    @Test
    func `a group that already balances leaves a zero per commodity`() throws {
        let text = """
        2024-01-01 Opening balances
            Assets:Savings      5 EUR
            Assets:Savings      -5 EUR
            Assets:Checking     $10
            Assets:Checking     $-10
            Equity:Opening
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let absorbed = transaction.postings.filter { $0.accountName == "Equity:Opening" }
        #expect(absorbed.map(\.amount) == [
            Amount(quantity: 0, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: 0, commodity: "EUR", commodityIsPrefix: false),
        ])
    }

    /// A written `0 EUR` is a commodity the group wrote, so it gets its zero
    /// beside the dollars that net out, as hledger prints it.
    @Test
    func `a written zero counts as a commodity the group wrote`() throws {
        let text = """
        2024-01-01 Opening balances
            Assets:Checking     $10
            Assets:Checking     $-10
            Assets:Savings      0 EUR
            Equity:Opening
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let absorbed = transaction.postings.filter { $0.accountName == "Equity:Opening" }
        #expect(absorbed.map(\.amount.commodity) == ["$", "EUR"])
        #expect(absorbed.allSatisfy { $0.amount.quantity == .zero })
    }

    /// A group written in one commodity still leaves exactly one zero.
    @Test
    func `a group in one commodity leaves one zero`() throws {
        let text = """
        2024-01-01 Opening balances
            Assets:Checking     $10.00
            Assets:Checking     $-10.00
            Equity:Opening
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let absorbed = transaction.postings.filter { $0.accountName == "Equity:Opening" }
        #expect(absorbed.map(\.amount) == [Amount(quantity: 0, commodity: "$", commodityIsPrefix: true)])
    }

    /// The entry nobody edited keeps its one elided line. Rebuilt, it writes
    /// one zero line per commodity, the way `hledger print -x` does.
    @Test
    func `a rebuilt entry writes a zero line per commodity`() throws {
        let text = """
        2024-01-01 Opening balances
            Assets:Checking     $10
            Assets:Checking     $-10
            Assets:Savings      5 EUR
            Assets:Savings      -5 EUR
            Equity:Opening
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

        let opening = JournalSerializer().serialize(journal)
            .components(separatedBy: "\n")
            .filter { $0.contains("Equity:Opening") }
        #expect(opening == ["    Equity:Opening      $0", "    Equity:Opening      0 EUR"])
    }
}
