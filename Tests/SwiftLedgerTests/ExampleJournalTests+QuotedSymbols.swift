import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's commodity symbol in quotes. Each topic of the
/// example keeps its tests in a file of its own, so that changes made side by
/// side add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    /// The fund entry writes its symbol in quotes, which are no part of the
    /// name, and an entry rebuilt in that commodity writes them back. The
    /// whole rebuilt line is compared, since the section comment quotes the
    /// name too and a search of the file would pass on that.
    @Test
    func `the example's fund is held in a quoted commodity`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        let bought = try #require(journal.transactions.first { $0.description == "Bought into an index fund" })
        #expect(bought.postings.first?.amount == Amount(quantity: 10, commodity: "Vanguard 500"))
        #expect(bought.postings.first?.price == .perUnit(Amount(quantity: 50, commodity: "$", commodityIsPrefix: true)))

        let renamed = try Transaction(
            id: bought.id,
            date: bought.date,
            auxDate: bought.auxDate,
            status: bought.status,
            code: bought.code,
            description: "Bought into an index fund (revised)",
            postings: bought.postings,
            comment: bought.comment,
            leadingComments: bought.leadingComments,
        )
        let replaced = journal.replace(.transaction(bought), with: .transaction(renamed))
        #expect(replaced)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("\n    Assets:Funds           10 \"Vanguard 500\" @ $50.00\n"))
    }

    /// The `commodity "BRK.B"` line names a symbol in quotes, which loads,
    /// and the same line with the quotes dropped is refused where it stands,
    /// as hledger refuses it, since the point is no part of a bare symbol.
    @Test
    func `the example's quoted commodity line loads and its bare form is refused`() throws {
        let text = try Self.exampleText
        let declaration = "\ncommodity \"BRK.B\"\n"
        let range = try #require(text.range(of: declaration))
        let line = text[..<range.lowerBound].count { $0 == "\n" } + 2
        _ = try JournalParser().parse(text)

        let bare = text.replacingCharacters(in: range, with: "\ncommodity BRK.B\n")
        #expect { try JournalParser().parse(bare) } throws: { error in
            guard let error = error as? LedgerError, error.line == line,
                  case .unreadableDirective = error.withoutLocation else { return false }
            return true
        }
    }
}
