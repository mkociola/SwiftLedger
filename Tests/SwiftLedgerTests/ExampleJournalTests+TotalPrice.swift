@testable import SwiftLedger
import Testing

/// Kept in a file of its own: `ExampleJournalTests.swift` is at the length
/// SwiftLint allows a file, so a new example test goes beside it rather than
/// into it.
extension ExampleJournalTests {
    /// The total price keeps the minus it is written with, so the euros cost
    /// -$110.00 and the positive cash leg is what balances them.
    @Test
    func `the example weighs a negative total price with its own sign`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Euros booked against a negative total" },
        )
        #expect(entry.postings.map(\.balancingAmount) == [
            Amount(quantity: -110, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: 110, commodity: "$", commodityIsPrefix: true),
        ])
    }
}
