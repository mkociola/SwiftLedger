@testable import SwiftLedger
import Testing

/// The tests for the example's commodity directive and the amount written
/// against it. Each topic of the example keeps its tests in a file of its own,
/// so that changes made side by side add to different files rather than all
/// growing one past the length SwiftLint allows.
extension ExampleJournalTests {
    /// `€1.000` is one euro where nothing is declared, and the directive
    /// above the entry is what makes it a thousand, as hledger reads it.
    @Test
    func `the example's commodity directive settles a whole thousand`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let invoice = try #require(
            journal.transactions.first { $0.description == "Freelance invoice paid in euros" },
        )
        #expect(invoice.postings.map(\.amount) == [
            Amount(quantity: 1000, commodity: "€", commodityIsPrefix: true),
            Amount(quantity: -1000, commodity: "€", commodityIsPrefix: true),
        ])
    }

    /// Under the directive, a lone mark that is not the declared comma groups
    /// whatever follows it, as hledger reads it: the tyres cost forty-five
    /// hundred euros rather than forty-five, and the amount reads that way
    /// with the point kept as written.
    @Test
    func `the example reads an amount written against its directive as hledger does`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let tyres = try #require(
            journal.transactions.first { $0.description == "Winter tyres, typed with the wrong mark" },
        )
        #expect(tyres.postings.map(\.amount) == [
            Amount(quantity: 4500, commodity: "€", commodityIsPrefix: true),
            Amount(quantity: -4500, commodity: "€", commodityIsPrefix: true),
        ])
    }

    /// The `decimal-mark ,` indented under the first account declaration is
    /// a subdirective hledger skips, and so does the parser: it declares
    /// nothing, the dollars below it are read with the point as every dollar
    /// entry in the file shows, and the opening balance is twenty-five
    /// hundred rather than a quarter of a million.
    @Test
    func `the example's indented decimal-mark under an account declares nothing`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        #expect(journal.commodityFormats["$"]?.decimalMark == ".")
        let opening = try #require(journal.transactions.first { $0.description == "Opening balances" })
        #expect(opening.postings.first?.amount.quantity == 2500)
    }

    /// The `format $1.000,00` under the same account is skipped too, by the
    /// serializer as well as the parser. Read by the serializer alone, it
    /// declared the comma for the dollar and outranked the `D` line, so the
    /// lunch rebuilt under that line was written `$25,00`, which reads back
    /// under the `D` line's point as twenty-five hundred dollars.
    @Test
    func `the example's indented format under an account leaves rebuilt dollars alone`() throws {
        var journal = try JournalParser().parse(Self.exampleText)
        let lunch = try #require(journal.transactions.first { $0.description == "Lunch, written without a symbol" })
        let dollars = { Amount(quantity: $0, commodity: "$", commodityIsPrefix: true) }
        let rebuilt = try Transaction(
            id: lunch.id, date: lunch.date, description: lunch.description, postings: [
                Posting(accountName: "Expenses:Food:Restaurants", amount: dollars(25)),
                Posting(accountName: "Assets:Checking", amount: dollars(-25)),
            ],
        )
        let replaced = journal.replace(.transaction(lunch), with: .transaction(rebuilt))
        #expect(replaced)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains(" $25.00\n"))
        let reparsed = try JournalParser().parse(written)
        let lunchAgain = try #require(reparsed.transactions.first { $0.description == lunch.description })
        #expect(lunchAgain.postings.map(\.amount.quantity) == [25, -25])
    }
}
