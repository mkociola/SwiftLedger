import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's default commodity. Each topic of the example
/// keeps its tests in a file of its own, so that changes made side by side
/// add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    /// The lunch is written as a bare number below the `D` line, so it is in
    /// dollars, and an entry rebuilt there writes the symbol in, in the
    /// style the file already writes its dollars in.
    @Test
    func `the example's bare number is in the default commodity`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        let lunch = try #require(journal.transactions.first { $0.description == "Lunch, written without a symbol" })
        #expect(lunch.postings.map(\.amount) == [
            Amount(quantity: 25, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -25, commodity: "$", commodityIsPrefix: true),
        ])

        let renamed = try Transaction(
            id: lunch.id, date: lunch.date, auxDate: lunch.auxDate, status: lunch.status, code: lunch.code,
            description: "Lunch, written without a symbol (revised)", postings: lunch.postings,
            comment: lunch.comment, leadingComments: lunch.leadingComments,
        )
        let replaced = journal.replace(.transaction(lunch), with: .transaction(renamed))
        #expect(replaced)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("\n    Expenses:Food:Restaurants  $25.00\n    Assets:Checking        -$25.00\n"))
    }
}
