@testable import SwiftLedger
import Testing

/// The tests for the example's virtual postings. Each section keeps its tests
/// in a file of its own, so that changes made side by side add to different
/// files rather than all growing one past the length SwiftLint allows.
extension ExampleJournalTests {
    @Test
    func `the example shows all three kinds of posting`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Groceries, and move the food envelope" },
        )
        #expect(entry.postings.map(\.kind) == [
            .real, .real, .balancedVirtual, .balancedVirtual, .virtual,
        ])
        #expect(entry.postings.map(\.accountName) == [
            "Expenses:Food:Groceries",
            "Assets:Checking",
            "Assets:Checking:Envelope:Food",
            "Assets:Checking:Available",
            "Reserve:Capital",
        ])
        #expect(entry.postings.map(\.amount.quantity) == [60, -60, -60, 60, 250])
    }
}
