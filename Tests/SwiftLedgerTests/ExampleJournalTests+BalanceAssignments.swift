@testable import SwiftLedger
import Testing

/// The tests for the example's balance assignment. Each topic of the example
/// keeps its tests in a file of its own, so that changes made side by side
/// add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    @Test
    func `the example shows a balance assignment`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let topUp = try #require(journal.transactions.first { $0.description == "Top up the petty cash tin" })

        #expect(topUp.postings.map(\.accountName) == ["Assets:PettyCash", "Assets:Checking"])
        #expect(topUp.postings.map(\.amount.quantity) == [50, -50])
        let asserted = Amount(quantity: 50, commodity: "$", commodityIsPrefix: true)
        #expect(topUp.postings.first?.balanceAssertion == asserted)
        #expect(topUp.postings.first?.balanceAssertionOperator == .single)
        #expect(Ledger(journal: journal).checkBalanceAssertions().isEmpty)
    }
}
