import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's decimal marks and its comment after an amount.
/// Each section keeps its tests in a file of its own, so that changes made side
/// by side add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    /// The comma in `€12,50` divides the fraction, so the coffee cost twelve
    /// euros fifty rather than the twelve hundred and fifty the parser used to
    /// read once it had stripped the comma out. One space before the `;` on
    /// the same line is enough to open the comment, which the parser used to
    /// swallow into the amount and drop.
    @Test
    func `the example shows a comma decimal mark and a comment after an amount`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Coffee in Vienna" },
        )
        #expect(try entry.postings.map(\.amount.quantity) == [
            #require(Decimal(string: "12.50")), #require(Decimal(string: "-12.50")),
        ])
        #expect(entry.postings.allSatisfy { $0.amount.commodity == "€" })
        #expect(entry.postings.map(\.comment) == ["one space is enough to start a comment", nil])
        #expect(journal.commodityFormats["€"]?.fractionDigits == 2)
    }

    /// The file writes its euros the way a European statement does and its
    /// dollars the way an American one does, and an entry rebuilt in it comes
    /// back in the style of its own commodity. Which characters the marks are
    /// is as much the file's style as the column it lines its amounts up at,
    /// and an edit that swapped them would respell every number in the entry
    /// the user touched.
    @Test
    func `the example writes a rebuilt entry with its own decimal marks`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        #expect(journal.commodityFormats["€"]?.decimalMark == ",")
        #expect(journal.commodityFormats["€"]?.groupMark == ".")
        #expect(journal.commodityFormats["€"]?.groupsThousands == true)
        #expect(journal.commodityFormats["$"]?.decimalMark == ".")

        let vienna = try #require(
            journal.transactions.first { $0.description == "Coffee in Vienna" },
        )
        let renamed = try Transaction(
            id: vienna.id,
            date: vienna.date,
            auxDate: vienna.auxDate,
            status: vienna.status,
            code: vienna.code,
            description: "Coffee in Vienna (revised)",
            postings: vienna.postings,
            comment: vienna.comment,
            leadingComments: vienna.leadingComments,
        )
        let replaced = journal.replace(.transaction(vienna), with: .transaction(renamed))
        #expect(replaced)

        // The whole rebuilt line, not a search of the file: the section
        // comments below write €12,50 themselves, so a substring would pass on
        // a rebuilt entry that had written anything at all. The amounts land
        // at the file's own margin of column 27, the account name too long for
        // it keeps the two spaces that end a name, and the comment a posting
        // carries comes back with the two spaces a rebuilt line writes.
        let written = JournalSerializer().serialize(journal)
        let lines = written.components(separatedBy: "\n")
        let header = try #require(lines.firstIndex(of: "2024-03-12 Coffee in Vienna (revised)"))
        #expect(Array(lines[(header + 1) ... (header + 2)]) == [
            "    Expenses:Food:Restaurants  €12,50  ; one space is enough to start a comment",
            "    Assets:EuroAccount     -€12,50",
        ])
        #expect(!written.contains("€12.50"))
    }

    /// An entry built in code joins the file in the file's own style, group
    /// mark and all. `Decimal(1500)` says nothing about how to write itself,
    /// and the euro entries above say `€1.500,00`.
    @Test
    func `an entry added to the example is written with its group mark`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        try journal.append(.transaction(Transaction(
            date: JournalDate(year: 2024, month: 3, day: 20),
            description: "Second transfer abroad",
            postings: [
                Posting(
                    accountName: "Assets:EuroAccount",
                    amount: Amount(quantity: 1500, commodity: "€", commodityIsPrefix: true),
                ),
                Posting(
                    accountName: "Equity:Opening",
                    amount: Amount(quantity: -1500, commodity: "€", commodityIsPrefix: true),
                ),
            ],
        )))

        let written = JournalSerializer().serialize(journal)
        let lines = written.components(separatedBy: "\n")
        let header = try #require(lines.firstIndex(of: "2024-03-20 Second transfer abroad"))
        #expect(Array(lines[(header + 1) ... (header + 2)]) == [
            "    Assets:EuroAccount     €1.500,00",
            "    Equity:Opening         -€1.500,00",
        ])
        #expect(!written.contains("€1,500.00"))
    }
}
