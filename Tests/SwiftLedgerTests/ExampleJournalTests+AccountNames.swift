@testable import SwiftLedger
import Testing

/// The tests for the example's alias and apply account lines. Each topic of
/// the example keeps its tests in a file of its own, so that changes made
/// side by side add to different files rather than all growing one past the
/// length SwiftLint allows.
extension ExampleJournalTests {
    /// Both entries are booked under the full names, as hledger books them,
    /// and keep the names the file wrote them under.
    @Test
    func `the example's short names book the full accounts`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let market = try #require(journal.transactions.first { $0.description.hasPrefix("Market") })
        #expect(market.postings.map(\.accountName) == ["Expenses:Food:Groceries", "Assets:Checking"])
        #expect(market.postings.map(\.writtenAccountName) == [nil, "checking"])
        let taxi = try #require(journal.transactions.first { $0.description == "A taxi first booked as a meal" })
        #expect(taxi.postings.map(\.accountName) == ["Expenses:Transport", "Expenses:Food:Restaurants"])
        #expect(taxi.postings.map(\.writtenAccountName) == ["Transport", "Food:Restaurants"])
    }

    /// Rebuilt, both entries are written with the names the file wrote, at
    /// the file's margin: the whole lines, not a search of the file, since
    /// the section's comment names the full accounts.
    @Test
    func `the example writes a rebuilt entry with its short names`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        let short = journal.transactions.filter { ["Market", "A taxi"].contains(where: $0.description.hasPrefix) }
        #expect(short.count == 2)
        for entry in short {
            let rebuilt = try Transaction(
                id: entry.id, date: entry.date, description: entry.description, postings: entry.postings,
            )
            let replaced = journal.replace(.transaction(entry), with: .transaction(rebuilt))
            #expect(replaced)
        }
        let text = JournalSerializer().serialize(journal)
        #expect(text.contains("""
        2024-03-22 Market, paid from checking by its short name
            Expenses:Food:Groceries  $18.00
            checking               -$18.00

        """))
        #expect(text.contains("""
        2024-03-22 A taxi first booked as a meal
            Transport              $15.00
            Food:Restaurants       -$15.00

        """))
    }
}
