@testable import SwiftLedger
import Testing

/// Kept in a file of its own: `ExampleJournalTests.swift` is at the length
/// SwiftLint allows a file, so a new example test goes beside it rather than
/// into it.
extension ExampleJournalTests {
    /// The reversed charges net to zero in both currencies, so the elided
    /// restaurants line reads as a zero in each, pounds before euros as
    /// hledger sorts them.
    @Test
    func `the example gives an elided line with nothing to absorb a zero per commodity`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Card charges abroad reversed by the bank" },
        )
        let absorbed = entry.postings.filter { $0.accountName == "Expenses:Food:Restaurants" }
        #expect(absorbed.map(\.amount) == [
            Amount(quantity: 0, commodity: "£", commodityIsPrefix: true),
            Amount(quantity: 0, commodity: "€", commodityIsPrefix: true),
        ])
    }
}
