@testable import SwiftLedger
import Testing

/// The tests for the example's comment blocks and other comment lines. Each
/// topic of the example keeps its tests in a file of its own, so that changes
/// made side by side add to different files rather than all growing one past
/// the length SwiftLint allows.
extension ExampleJournalTests {
    /// The comment block in the example parks a rent entry that must not be
    /// booked. If it were, rent would be three months rather than two and the
    /// block's lines would not come back as the directives the round-trip
    /// relies on.
    @Test
    func `the example's comment block is text, not data`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        #expect(!journal.transactions.contains { $0.description == "Rent for March" })
        #expect(journal.directives == [
            "    decimal-mark ,",
            "    format $1.000,00",
            "commodity €1.000,00",
            // The line of four spaces under the car wash is kept as it came.
            "    ",
            "comment",
            "Draft of the March rent, not yet due. Everything in here is text.",
            "2024-03-01 * Rent for March",
            "    Expenses:Rent          $1200.00",
            "    Assets:Checking",
            "end comment",
            "commodity \"BRK.B\"",
            "D $1000.00",
            "include sample-include.ledger",
            "alias checking = Assets:Checking",
            "end aliases",
            "apply account Expenses",
            "end apply account",
            "decimal-mark .",
            "decimal-mark ,",
        ])
        let rent = Ledger(journal: journal).balance(for: "Expenses:Rent")
        #expect(rent.map(\.quantity) == [2400])
    }

    @Test
    func `the example's % and | lines are comments`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let markers = journal.items.compactMap { item -> Character? in
            guard case let .comment(text) = item else { return nil }
            return text.first
        }
        #expect(markers.contains("%"))
        #expect(markers.contains("|"))
    }

    /// The parking entry writes its comment after one space, and a `;` in its
    /// code. The description stops at the first `;` past the code, as hledger
    /// reads it, so the note is the entry's comment and not part of the payee.
    @Test
    func `the example reads a comment after one space on the entry line`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let parking = try #require(journal.transactions.first { $0.code == "P;7" })
        #expect(parking.description == "Parking")
        #expect(parking.comment == "paid at the machine")
    }
}
