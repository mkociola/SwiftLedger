import Foundation
@testable import SwiftLedger
import Testing

/// `Examples/sample.ledger` is what the README points a reader at as a
/// complete journal, so it has to load with the parser it ships beside, and
/// what it demonstrates has to be true.
@Suite("example journal") struct ExampleJournalTests {
    /// The example file, read from the repository rather than bundled, so
    /// that editing it is enough to test it.
    private static var exampleText: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // SwiftLedgerTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // repository root
                .appending(path: "Examples/sample.ledger")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test
    func `the example parses and is written back byte-for-byte`() throws {
        let text = try Self.exampleText
        let journal = try JournalParser().parse(text)
        #expect(!journal.transactions.isEmpty)
        #expect(JournalSerializer().serialize(journal) == text)
    }

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

    @Test
    func `the example shows all three kinds of posting`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Groceries, and move the food envelope" },
        )
        #expect(entry.postings.map(\.kind) == [
            .real, .real, .balancedVirtual, .balancedVirtual, .virtual,
        ])
        #expect(entry.postings.map(\.accountName) == [
            "Expenses:Food:Groceries",
            "Assets:Checking",
            "Assets:Checking:Envelope:Food",
            "Assets:Checking:Available",
            "Reserve:Capital",
        ])
        #expect(entry.postings.map(\.amount.quantity) == [60, -60, -60, 60, 250])
    }

    /// The opening entry for the accounts abroad is the hledger idiom the
    /// parser used to reject: two commodities and one elided line to absorb
    /// both. It reads as one posting per commodity, and a commodity the
    /// written postings already net to zero gets no posting at all.
    @Test
    func `the example shows an elided posting absorbing several commodities`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let byPayee = Dictionary(
            journal.transactions.map { ($0.description, $0) },
            uniquingKeysWith: { first, _ in first },
        )

        let opening = try #require(byPayee["Opening balances for the accounts abroad"])
        #expect(opening.postings.map(\.accountName) == [
            "Assets:EuroAccount", "Assets:PoundAccount", "Equity:Opening", "Equity:Opening",
        ])
        #expect(opening.postings.map(\.amount) == [
            Amount(quantity: 1500, commodity: "€", commodityIsPrefix: true),
            Amount(quantity: 400, commodity: "£", commodityIsPrefix: true),
            Amount(quantity: -1500, commodity: "€", commodityIsPrefix: true),
            Amount(quantity: -400, commodity: "£", commodityIsPrefix: true),
        ])

        let abroad = try #require(byPayee["Lunch and a train abroad"])
        #expect(abroad.postings.count == 4)
        #expect(abroad.postings.last?.accountName == "Assets:PoundAccount")
        #expect(abroad.postings.last?.amount == Amount(quantity: -25, commodity: "£", commodityIsPrefix: true))

        let ledger = try Ledger(journal: journal)
        #expect(ledger.balance(for: "Equity:Opening") == [
            Amount(quantity: -7500, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -400, commodity: "£", commodityIsPrefix: true),
            Amount(quantity: -1500, commodity: "€", commodityIsPrefix: true),
        ])
    }

    /// The comma in `€12,50` divides the fraction, so the coffee cost twelve
    /// euros fifty rather than the twelve hundred and fifty the parser used to
    /// read once it had stripped the comma out.
    @Test
    func `the example shows a comma decimal mark`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Coffee in Vienna" },
        )
        #expect(try entry.postings.map(\.amount.quantity) == [
            #require(Decimal(string: "12.50")), #require(Decimal(string: "-12.50")),
        ])
        #expect(entry.postings.allSatisfy { $0.amount.commodity == "€" })
        #expect(journal.commodityFormats["€"]?.fractionDigits == 2)
    }

    /// The example is also a style sample: every entry a reader adds to it,
    /// and every entry SwiftLedger rebuilds in it, is laid out from what the
    /// file already shows. An entry that lines its amounts up somewhere new,
    /// or that writes the file's first negative amount the other way round,
    /// moves that answer for the whole file. That is how the virtual-posting
    /// entry silently flipped the margin from 27 to 31 and the sign from `-$`
    /// to `$-` before it was aligned.
    @Test
    func `the example teaches one margin and one negative-sign style`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        #expect(journal.amountAlignment == .start(column: 27))
        #expect(journal.commodityFormats["$"]?.signPrecedesCommodity == true)
    }

    /// The library preserves a balance assertion without checking it, so the
    /// example has to be honest on its own: the figure it asserts is the
    /// balance the entries above it produce.
    @Test
    func `the asserted balance in the example is the real one`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(Self.exampleText))
        let savings = ledger.balance(for: "Assets:Savings")
        #expect(savings.map(\.quantity) == [5000])
        #expect(ledger.balance(for: "Assets:Brokerage").allSatisfy { $0.quantity == 0 })
        #expect(ledger.balance(for: "Assets:PettyCash").allSatisfy { $0.quantity == 0 })
    }

    /// The comment block in the example parks a rent entry that must not be
    /// booked. If it were, rent would be three months rather than two and the
    /// block's lines would not come back as the directives the round-trip
    /// relies on.
    @Test
    func `the example's comment block is text, not data`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        #expect(!journal.transactions.contains { $0.description == "Rent for March" })
        #expect(journal.directives == [
            "comment",
            "Draft of the March rent, not yet due. Everything in here is text.",
            "2024-03-01 * Rent for March",
            "    Expenses:Rent          $1200.00",
            "    Assets:Checking",
            "end comment",
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
}
