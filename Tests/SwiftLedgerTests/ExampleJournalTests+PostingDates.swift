@testable import SwiftLedger
import Testing

extension ExampleJournalTests {
    /// The water bill's checking posting is dated by its `date:` tag, so the
    /// bill leaves the account on April 2nd, not on the entry's March 29th.
    /// Read before posting dates were, it left on the 29th.
    @Test
    func `the example's water bill leaves checking on the day it cleared`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(Self.exampleText))
        let payee = "Water bill, cleared on the 2nd"
        let bill = try #require(ledger.journal.transactions.first { $0.description == payee })
        #expect(try bill.date == JournalDate(year: 2024, month: 3, day: 29))
        #expect(try bill.postings.map(\.date) == [nil, JournalDate(year: 2024, month: 4, day: 2)])
        #expect(bill.postings[1].comment == "date:2024-04-02")

        let march = try ledger.balance(for: "Assets:Checking", asOf: JournalDate(year: 2024, month: 3, day: 31))
        let april = try ledger.balance(for: "Assets:Checking", asOf: JournalDate(year: 2024, month: 4, day: 2))
        #expect(april.map(\.quantity) == march.map { $0.quantity - 31 })
    }
}
