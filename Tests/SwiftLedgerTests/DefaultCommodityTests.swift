import Foundation
@testable import SwiftLedger
import Testing

/// A number written without a commodity is in the commodity a `D` line
/// above it names, with the side its sample shows, and in no commodity at
/// all where no such line stands above it, as hledger reads both. It used to
/// be `USD` either way, so a journal kept with `D $1,000.00` and bare
/// numbers loaded with every figure in a currency it never wrote, and a
/// rebuilt entry wrote `1200 USD` into it. Issue #39.
@Suite("the default commodity") struct DefaultCommodityTests {
    static func amounts(in text: String) throws -> [Amount] {
        try JournalParser().parse(text).transactions.flatMap { $0.postings.map(\.amount) }
    }

    static func entry(_ amounts: Amount...) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2024, month: 1, day: 1),
            description: "Rent",
            postings: amounts.map { Posting(accountName: "Expenses:Rent", amount: $0) },
        )
    }

    @Test(arguments: [
        ("D $1,000.00", Amount(quantity: 1200, commodity: "$", commodityIsPrefix: true)),
        ("D 1,000.00 EUR", Amount(quantity: 1200, commodity: "EUR")),
        ("D USD 1,000.00", Amount(quantity: 1200, commodity: "USD", commodityIsPrefix: true)),
    ])
    func `a bare number below a D line is in its commodity, on its side`(directive: String, expected: Amount) throws {
        let text = "\(directive)\n\n2024-01-01 Rent\n    Expenses:Rent    1200\n    Assets:Checking\n"
        #expect(try Self.amounts(in: text) == [expected, expected.negated])
    }

    /// Without a `D` line a bare number is in no commodity, the elided
    /// posting absorbs it as such, and the format records no side for it,
    /// since no amount wrote the name anywhere.
    @Test
    func `a bare number with no D line is in no commodity`() throws {
        let journal = try JournalParser().parse("2024-01-01 Rent\n    Expenses:Rent    1200\n    Assets:Checking\n")
        #expect(journal.transactions.first?.postings.map(\.amount) == [
            Amount(quantity: 1200, commodity: ""), Amount(quantity: -1200, commodity: ""),
        ])
        #expect(journal.commodityFormats[""]?.commodityIsPrefix == nil)
    }

    @Test
    func `a bare price and assertion follow the same rule`() throws {
        let text = "2024-01-01 Shares\n    Assets:Fund    10 @ 5 = 10\n    Assets:Checking    -50\n"
        let posting = try #require(JournalParser().parse(text).transactions.first?.postings.first)
        #expect(posting.price == .perUnit(Amount(quantity: 5, commodity: "")))
        #expect(posting.balanceAssertion == Amount(quantity: 10, commodity: ""))
    }

    /// The directive speaks from the line it stands on: above it a bare
    /// number is in no commodity, and a second `D` replaces the first.
    @Test
    func `a D line reaches the bare numbers below it, until the next one`() throws {
        let text = """
        2024-01-01 above
            Expenses:Rent    5
            Assets:Checking

        D $1,000.00

        2024-01-02 below
            Expenses:Rent    7
            Assets:Checking

        D 1.000,00 EUR

        2024-01-03 further below
            Expenses:Rent    9
            Assets:Checking
        """
        #expect(try Self.amounts(in: text).map(\.commodity) == ["", "", "$", "$", "EUR", "EUR"])
    }

    /// A `D` sample written bare names no commodity, so the bare numbers
    /// below it stay in none, as in hledger, where it still states their
    /// style.
    @Test
    func `a bare D sample names no commodity`() throws {
        let text = "D 1,000.00\n\n2024-01-01 Rent\n    Expenses:Rent    1200\n    Assets:Checking\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.map(\.amount.commodity) == ["", ""])
        #expect(journal.commodityFormats[""]?.fractionDigits == 2)
    }

    @Test
    func `a written commodity is not replaced by the default`() throws {
        let text = "D $1,000.00\n\n2024-01-01 Rent\n    Expenses:Rent    1200 EUR\n    Assets:Checking\n"
        #expect(try Self.amounts(in: text).map(\.commodity) == ["EUR", "EUR"])
    }

    /// An amount in no commodity is written as the bare number it was read
    /// from, with no symbol and no space left where one would go, on either
    /// side.
    @Test(arguments: [false, true])
    func `a rebuilt amount in no commodity is written bare`(isPrefix: Bool) throws {
        let entry = try Self.entry(
            Amount(quantity: 1200, commodity: "", commodityIsPrefix: isPrefix),
            Amount(quantity: -1200, commodity: "", commodityIsPrefix: isPrefix),
        )
        let lines = JournalSerializer().serialize(Journal(items: [.transaction(entry)])).components(separatedBy: "\n")
        #expect(lines[1].hasSuffix("  1200"))
        #expect(lines[2].hasSuffix("  -1200"))
    }

    /// Below a `D` line the bare number is in that commodity, so an entry
    /// rebuilt there writes the symbol in, in the style the sample states,
    /// as hledger's `print` writes it.
    @Test
    func `a rebuilt bare amount below a D line is written in the default commodity`() throws {
        let text = "D $1000.00\n\n2024-01-01 Rent\n    Expenses:Rent    1200\n    Assets:Checking\n"
        var journal = try JournalParser().parse(text)
        let rent = try #require(journal.transactions.first)
        let renamed = try Transaction(
            id: rent.id, date: rent.date, auxDate: rent.auxDate, status: rent.status, code: rent.code,
            description: "Rent (revised)", postings: rent.postings, comment: rent.comment,
            leadingComments: rent.leadingComments,
        )
        let replaced = journal.replace(.transaction(rent), with: .transaction(renamed))
        #expect(replaced)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("  $1200.00\n"))
        #expect(written.contains("  -$1200.00\n"))
    }

    /// An amount built in code with no commodity is one the serializer can
    /// write, so `Transaction.init` takes it, and it reads back as itself
    /// from a file with no `D` line.
    @Test
    func `an amount in no commodity reads back as itself`() throws {
        let amount = Amount(quantity: 1200, commodity: "")
        let entry = try Self.entry(amount, amount.negated)
        let written = JournalSerializer().serialize(Journal(items: [.transaction(entry)]))
        #expect(try JournalParser().parse(written).transactions.first?.postings.first?.amount == amount)
    }
}
