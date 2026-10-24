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

    /// Both card postings the ferry entry's elided line splits into are dated
    /// April 3rd, and rebuilt, each is written with the date. Written back
    /// without the tag on the euro leg, the next load dated it March 30th.
    @Test
    func `the example's split ferry line keeps its date when rebuilt`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        let ferry = try #require(journal.transactions.first { $0.description.hasPrefix("Ferry tickets") })
        let cleared = try JournalDate(year: 2024, month: 4, day: 3)
        #expect(ferry.postings.map(\.date) == [nil, nil, cleared, cleared])

        let rebuilt = try Transaction(date: ferry.date, description: ferry.description, postings: ferry.postings)
        let replaced = journal.replace(.transaction(ferry), with: .transaction(rebuilt))
        #expect(replaced)
        let text = JournalSerializer().serialize(journal)
        #expect(text.contains("""
            Liabilities:TravelCard  -£9.00  ; date:2024-04-03
            Liabilities:TravelCard  -€12,00  ; date:2024-04-03

        """))
        let reread = try #require(JournalParser().parse(text).transactions.first {
            $0.description == ferry.description
        })
        #expect(reread.postings.map(\.date) == [nil, nil, cleared, cleared])
    }
}
