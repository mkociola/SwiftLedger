import Foundation
@testable import SwiftLedger
import Testing

/// The parser reads an indented `format` line only under a `commodity` block,
/// as hledger does, and skips one under an `account`, `payee` or `tag` block
/// or inside a periodic or automated entry. The serializer used to read one
/// wherever it stood, so a `format 1.000,00 EUR` under an `account` block
/// declared the comma for EUR where the parser read EUR by the point of a `D`
/// line, and a rebuilt `4.50 EUR` was written `4,50 EUR`, which read back as
/// 450 EUR. The entry balanced either way, so the file loaded without a word.
@Suite("a format line declares a style only under a commodity block") struct SerializerFormatOwnerTests {
    /// One journal, and what 4.50 EUR is written as where its entry stands.
    struct Layout {
        var journal: String
        var written: String
    }

    static let layouts: [Layout] = [
        // The journal from the review: the `format` line belongs to the
        // account, so the point of the `D` line is in force for EUR.
        Layout(journal: """
        account Assets:Bank
          format 1.000,00 EUR

        D $1,000.00

        2024-01-01 Coffee
            Expenses:Food    4.50 EUR
            Assets:Bank
        """, written: "4.50 EUR"),
        // Under a `commodity` block the `format` line is read, and its comma
        // outranks the point of the `D` line.
        Layout(journal: """
        commodity EUR
          format 1.000,00 EUR

        D $1,000.00

        2024-01-01 Coffee
            Expenses:Food    4,50 EUR
            Assets:Bank
        """, written: "4,50 EUR"),
    ]

    /// The coffee entry rebuilt in code is written with the mark the parser
    /// reads EUR by, and reads back as 4.50 EUR.
    @Test(arguments: SerializerFormatOwnerTests.layouts)
    func `a rebuilt amount is written by the mark the parser reads`(layout: Layout) throws {
        var journal = try JournalParser().parse(layout.journal)
        let coffee = try #require(journal.transactions.first)
        let price = try #require(Decimal(string: "4.50"))
        #expect(coffee.postings.first?.amount.quantity == price)
        let money = { Amount(quantity: $0, commodity: "EUR", commodityIsPrefix: false) }
        let rebuilt = try Transaction(
            id: coffee.id, date: coffee.date, description: coffee.description, postings: [
                Posting(accountName: "Expenses:Food", amount: money(price)),
                Posting(accountName: "Assets:Bank", amount: money(-price)),
            ],
        )
        let replaced = journal.replace(.transaction(coffee), with: .transaction(rebuilt))
        #expect(replaced)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains(" \(layout.written)\n"))
        let reparsed = try #require(JournalParser().parse(written).transactions.first)
        #expect(reparsed.postings.map(\.amount.quantity) == [price, -price])
    }
}
