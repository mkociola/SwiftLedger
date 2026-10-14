import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's entries in several commodities. Each topic of
/// the example keeps its tests in a file of its own, so that changes made side
/// by side add to different files rather than all growing one past the length
/// SwiftLint allows.
extension ExampleJournalTests {
    /// The opening entry for the accounts abroad is the hledger idiom the
    /// parser used to reject: two commodities and one elided line to absorb
    /// both. It reads as one posting per commodity, sorted by symbol as
    /// hledger sorts them, so the pound comes before the euro the entry wrote
    /// first, and a commodity the written postings already net to zero gets
    /// no posting at all.
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
            Amount(quantity: -400, commodity: "£", commodityIsPrefix: true),
            Amount(quantity: -1500, commodity: "€", commodityIsPrefix: true),
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

    /// The franc entry writes its code in front with a space. The space is
    /// not in the commodity's name, and the format is what remembers it.
    @Test
    func `the example's franc entry is in CHF, written with a space`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let dinner = try #require(journal.transactions.first { $0.description == "Dinner in Zurich" })
        #expect(dinner.postings.map(\.amount) == [
            Amount(quantity: 80, commodity: "CHF", commodityIsPrefix: true),
            Amount(quantity: -80, commodity: "CHF", commodityIsPrefix: true),
        ])
        #expect(journal.commodityFormats["CHF"]?.commodityIsPrefix == true)
        #expect(journal.commodityFormats["CHF"]?.separatesPrefixCommodity == true)
    }

    /// The share transfer sets its sign apart from the number and writes the
    /// commodity behind it. Read with the space left on the number, the whole
    /// example stops loading.
    @Test
    func `the example's share transfer reads a sign set apart from its number`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let moved = try #require(journal.transactions.first { $0.description == "Shares moved to another broker" })
        #expect(moved.postings.map(\.amount) == [
            Amount(quantity: -4, commodity: "VTI"),
            Amount(quantity: 4, commodity: "VTI"),
        ])
    }

    /// The sign is written once. Doubled in the share transfer, with or
    /// without the commodity behind the number, it is no amount, and the
    /// example stops loading on that amount, named as the file wrote it.
    @Test(arguments: ["- - 4 VTI", "- - 4"])
    func `the example's share transfer is refused with its sign doubled`(doubled: String) throws {
        let text = try Self.exampleText.replacingOccurrences(of: "- 4 VTI", with: doubled)
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .invalidAmount(doubled))
    }
}
