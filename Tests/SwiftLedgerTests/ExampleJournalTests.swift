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

    /// Two commodities and no price on either line is an exchange, and the
    /// entry balances on the rate the amounts imply. The file keeps no record
    /// of that rate, which is why it is asked for rather than read.
    @Test
    func `the example shows an exchange with no price written`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Bought euros at the bureau" },
        )
        #expect(entry.postings.allSatisfy { $0.price == nil })
        #expect(entry.balance.isBalanced)
        let conversion = try #require(entry.balance.real.conversion)
        #expect(conversion.postingIndices == [0])
        #expect(conversion.price == .total(
            Amount(quantity: 110, commodity: "$", commodityIsPrefix: true),
        ))
    }

    /// A price is what lets two postings that share no commodity balance: the
    /// restaurant account holds thirty euros, the card owes the $32.70 they
    /// cost, and the entry nets to zero on the cost alone.
    @Test
    func `the example shows a posting priced in another commodity`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let entry = try #require(
            journal.transactions.first { $0.description == "Dinner in Vienna, paid with the card" },
        )
        let rate = try #require(Decimal(string: "1.09"))
        let cost = try #require(Decimal(string: "32.70"))
        #expect(entry.postings[0].amount == Amount(quantity: 30, commodity: "€", commodityIsPrefix: true))
        #expect(entry.postings[0].price == .perUnit(
            Amount(quantity: rate, commodity: "$", commodityIsPrefix: true),
        ))
        #expect(entry.postings[0].balancingAmount
            == Amount(quantity: cost, commodity: "$", commodityIsPrefix: true))
        #expect(entry.postings[1].amount == Amount(quantity: -cost, commodity: "$", commodityIsPrefix: true))
    }

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
