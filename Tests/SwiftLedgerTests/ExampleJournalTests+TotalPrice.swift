@testable import SwiftLedger
import Testing

/// The tests for the example's total price with a sign of its own. Each section
/// keeps its tests in a file of its own, so that changes made side by side add
/// to different files rather than all growing one past the length SwiftLint
/// allows.
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
