@testable import SwiftLedger
import Testing

/// The tests for the example's entries with fewer than two postings. Each
/// section keeps its tests in a file of its own, so that changes made side by
/// side add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    @Test
    func `the example shows entries with fewer than two postings`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let byPayee = Dictionary(
            journal.transactions.map { ($0.description, $0) },
            uniquingKeysWith: { first, _ in first },
        )

        let note = try #require(byPayee["Called the bank about the card fee"])
        #expect(note.postings.isEmpty)

        let brokerage = try #require(byPayee["Opened a brokerage account"])
        #expect(brokerage.postings.map(\.accountName) == ["Assets:Brokerage"])
        #expect(brokerage.postings.map(\.amount.quantity) == [0])

        let petty = try #require(byPayee["Set up the petty cash tin"])
        #expect(petty.postings.map(\.accountName) == ["Assets:PettyCash"])
        #expect(petty.postings.map(\.amount.quantity) == [0])

        let check = try #require(byPayee["Statement check"])
        #expect(check.postings.map(\.accountName) == ["Assets:Savings"])
        #expect(check.postings.map(\.amount.quantity) == [0])
        let asserted = Amount(quantity: 5000, commodity: "$", commodityIsPrefix: true)
        #expect(check.postings.first?.balanceAssertion == asserted)
    }
}
