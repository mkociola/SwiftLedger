import Foundation
@testable import SwiftLedger
import Testing

/// A number with one mark and exactly three digits after it says nothing
/// about which mark it is, and the parser used to settle it by a fixed rule
/// however the file was declared: `€1.000` under `commodity €1.000,00` loaded
/// as one euro, and the first edit wrote that one euro back in the declared
/// style (issue #33). hledger reads `commodity`, `D` and `decimal-mark`
/// directives for this, from the line each stands on, and so does the parser
/// now. Without a directive the reading is the one the library has always
/// had, which `AmountValidationTests` pins.
@Suite("decimal mark directives") struct DecimalMarkDirectiveTests {
    /// Every posting amount in the file, in order.
    private static func quantities(in text: String) throws -> [Decimal] {
        try JournalParser().parse(text).transactions.flatMap { $0.postings.map(\.amount.quantity) }
    }

    /// The journal from the issue: declared, the whole thousand is a thousand,
    /// the directive goes back as written, and the figures are hledger's.
    @Test
    func `the journal from the issue loads as hledger reads it`() throws {
        let text = """
        commodity €1.000,00

        2024-01-01 opening
            assets:bank      €1.000
            equity:opening  €-1.000

        2024-01-02 groceries
            expenses:food     €12,50
            assets:bank      €-12,50
        """
        let journal = try JournalParser().parse(text)
        let ledger = Ledger(journal: journal)
        #expect(try ledger.balance(for: "assets:bank") == [
            Amount(quantity: #require(Decimal(string: "987.50")), commodity: "€", commodityIsPrefix: true),
        ])
        #expect(journal.directives == ["commodity €1.000,00"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Each way a file states a commodity's style settles the shape, and
    /// settles it both ways round: under a comma declaration `€1,000` is one
    /// euro to three places, as it is in hledger. A tab after the keyword is
    /// the space hledger allows there, not a line to drop.
    @Test(arguments: [
        "D €1.000,00", "D\t€1.000,00", "commodity €1.000,00", "commodity €\n    format €1.000,00",
        "decimal-mark ,", "decimal-mark\t,",
    ])
    func `a declared decimal mark settles a lone mark before three digits`(directive: String) throws {
        let text = """
        \(directive)

        2024-01-01 opening
            assets:bank      €1.000
            assets:cash      €1,000
            equity:opening  €-1.001
        """
        #expect(try Self.quantities(in: text) == [1000, 1, -1001])
    }

    /// The directive speaks from the line it stands on: an amount above it
    /// keeps the reading the file would have without it.
    @Test
    func `a directive settles only the amounts after it`() throws {
        let text = """
        2024-01-01 before
            assets:bank      €1.000
            equity:opening  €-1.000

        commodity €1.000,00

        2024-01-02 after
            assets:bank      €1.000
            equity:opening  €-1.000
        """
        #expect(try Self.quantities(in: text) == [1, -1, 1000, -1000])
    }

    /// `decimal-mark` names no commodity and reaches all of them, a comment
    /// behind it and all, until another `decimal-mark` line says otherwise.
    /// Like every directive, each line goes back byte for byte.
    @Test
    func `decimal-mark applies to every commodity until the next one`() throws {
        let text = """
        decimal-mark , ; the European way

        2024-01-01 grouped
            assets:bank      €1.000
            equity:opening  €-1.000
            assets:cash      $1.000
            equity:opening  $-1.000
            assets:other     1.000 EUR
            equity:opening  -1.000 EUR

        decimal-mark .

        2024-01-02 divided
            assets:bank      €1.000
            equity:opening  €-1.000
        """
        let journal = try JournalParser().parse(text)
        let quantities = journal.transactions.flatMap { $0.postings.map(\.amount.quantity) }
        #expect(quantities == [1000, -1000, 1000, -1000, 1000, -1000, 1, -1])
        #expect(journal.directives == ["decimal-mark , ; the European way", "decimal-mark ."])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// `D` declares a default commodity, and hledger reads every commodity
    /// without a declaration of its own by that commodity's marks. A later
    /// `D` names another default, and the first commodity's marks go with it.
    @Test
    func `a D directive reaches every commodity without its own declaration`() throws {
        let text = """
        D €1.000,00

        2024-01-01 euros settle dollars
            assets:cash      $1.000
            equity:opening  $-1.000

        D $1,000.00

        2024-01-02 and dollars settle euros
            assets:bank      €1.000
            equity:opening  €-1.000
        """
        #expect(try Self.quantities(in: text) == [1000, -1000, 1, -1])
    }

    /// A bare number is in no commodity, however `Amount` later names it, so
    /// a `commodity` directive says nothing about how one is read, not even
    /// a directive for the `USD` a bare number is read as. hledger reads one
    /// by `decimal-mark` and `D` alone, and `D` may state its sample bare.
    /// The harness cannot pin this until #39, since hledger names the
    /// commodity differently.
    @Test
    func `a bare number is read by decimal-mark and D alone`() throws {
        let text = """
        commodity 1.000,00 USD

        2024-01-01 the USD directive does not reach a bare number
            expenses:rent    1.000
            assets:bank     -1.000

        D 1.000,00

        2024-01-02 a bare D sample does
            expenses:rent    1.000
            assets:bank     -1.000
        """
        #expect(try Self.quantities(in: text) == [1, -1, 1000, -1000])
    }

    /// Where the directives disagree, hledger's order holds: `decimal-mark`
    /// outranks a `commodity` directive, which outranks `D`, whichever came
    /// first.
    @Test
    func `decimal-mark outranks a commodity directive, which outranks D`() throws {
        let text = """
        commodity €1.000,00
        D €1,000.00

        2024-01-01 the commodity directive wins
            assets:bank      €1.000
            equity:opening  €-1.000

        decimal-mark .

        2024-01-02 decimal-mark wins
            assets:bank      €1.000
            equity:opening  €-1.000
        """
        #expect(try Self.quantities(in: text) == [1000, -1000, 1, -1])
    }

    /// A price and a balance assertion are read by the same directive as the
    /// amount in front of them.
    @Test
    func `a price and an assertion are settled too`() throws {
        let text = """
        commodity €1.000,00

        2024-01-01 shares
            assets:shares    10 X @ €1.000
            assets:bank      €-10.000 = €-10.000
        """
        let entry = try #require(JournalParser().parse(text).transactions.first)
        #expect(entry.postings.first?.price
            == .perUnit(Amount(quantity: 1000, commodity: "€", commodityIsPrefix: true)))
        #expect(entry.postings.map(\.amount.quantity) == [10, -10000])
        #expect(entry.postings.last?.balanceAssertion
            == Amount(quantity: -10000, commodity: "€", commodityIsPrefix: true))
    }

    /// An amount a directive settled is settled, and votes on the file's marks
    /// like any other: a file of whole thousands under `decimal-mark ,` learns
    /// the comma and the grouping that the same amounts, unsettled, could not
    /// teach it.
    @Test
    func `a settled amount votes on the file's marks`() throws {
        let entries = """
        2024-01-01 rent
            expenses:rent    €1.000
            assets:bank     €-1.000

        2024-02-01 rent
            expenses:rent    €1.000
            assets:bank     €-1.000
        """
        let undeclared = try JournalParser().parse(entries).commodityFormats["€"]
        #expect(undeclared?.decimalMark == ".")
        #expect(undeclared?.groupsThousands == false)

        let declared = try JournalParser().parse("decimal-mark ,\n\n" + entries).commodityFormats["€"]
        #expect(declared?.decimalMark == ",")
        #expect(declared?.groupsThousands == true)
        #expect(declared?.fractionDigits == 0)
    }

    /// The consequence from the issue: a file of `€1.000` amounts and one
    /// `€12,50` used to learn three places from the thousands and write a
    /// rebuilt twelve fifty as `€12,5000`, the fourth place keeping the comma
    /// from reading as a group mark. Declared, the thousands have no places
    /// at all, and the rebuilt amount is written as the file writes one.
    @Test
    func `a rebuilt amount in a declared file is not padded against the tie-break`() throws {
        var journal = try JournalParser().parse("""
        decimal-mark ,

        2024-01-01 rent
            expenses:rent    €1.000
            assets:bank     €-1.000

        2024-01-02 coffee
            expenses:food    €12,50
            assets:bank     €-12,50
        """)
        let coffee = try #require(journal.transactions.last)
        let renamed = try Transaction(
            id: coffee.id, date: coffee.date, description: "coffee (revised)", postings: coffee.postings,
        )
        let replaced = journal.replace(.transaction(coffee), with: .transaction(renamed))
        #expect(replaced)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("€12,50"))
        #expect(!written.contains("€12,5000"))
        let reparsed = try #require(JournalParser().parse(written).transactions.last)
        #expect(reparsed.postings.map(\.amount.quantity) == [Decimal(string: "12.5"), Decimal(string: "-12.5")])
    }

    /// A sample that names no mark declares nothing about the marks, so it
    /// cannot take away what an earlier directive declared: `€1.000` is still
    /// a thousand below both lines. hledger refuses the mark-less sample.
    @Test
    func `a sample without a mark leaves an earlier declaration standing`() throws {
        let text = """
        commodity €1.000,00
        commodity €1000

        2024-01-01 rent
            expenses:rent    €1.000
            assets:bank     €-1.000
        """
        #expect(try Self.quantities(in: text) == [1000, -1000])
    }

    /// A directive's own sample is read with the marks declared above it, so
    /// `D €1.000` under `decimal-mark ,` states a grouped whole number rather
    /// than one euro to three places.
    @Test
    func `a directive's sample is read by the directives above it`() throws {
        let alone = try JournalParser().parse("D €1.000").commodityFormats["€"]
        #expect(alone?.fractionDigits == 3)
        #expect(alone?.groupsThousands == false)

        let declared = try JournalParser().parse("decimal-mark ,\nD €1.000").commodityFormats["€"]
        #expect(declared?.fractionDigits == 0)
        #expect(declared?.groupsThousands == true)
        #expect(declared?.decimalMark == ",")
    }
}
