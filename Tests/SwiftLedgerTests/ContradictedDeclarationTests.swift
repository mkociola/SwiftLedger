import Foundation
@testable import SwiftLedger
import Testing

/// Under a directive, hledger reads every lone mark by the directive rather
/// than by the number it sits in: the declared mark divides and any other
/// mark groups, whatever follows it (issue #77). `DecimalMarkDirectiveTests`
/// covers the directives themselves and the one shape a number cannot settle;
/// this suite covers amounts written against what the file declares, and the
/// directive whose own sample has one mark.
@Suite("amounts written against a declaration") struct ContradictedDeclarationTests {
    /// Under a declaration, hledger reads a lone mark by the directive rather
    /// than by the number: the declared mark divides, and any other mark
    /// groups whatever digits sit after it, so `€12.50` under `decimal-mark ,`
    /// is twelve hundred and fifty. The two rules a number settles itself by
    /// where nothing is declared, that a mark with anything but three digits
    /// after it divides and that nothing groups a zero, are not consulted
    /// under one. A mark with nothing after it divides under either
    /// declaration, since there is nothing to its right to group, and read as
    /// a group mark it would have been no number at all. An amount written
    /// against the declaration is most likely a typo, and reading it as the
    /// number says loads a figure a hundred times apart from hledger's.
    @Test(arguments: ContradictedDeclarationTests.contradictedAmounts)
    func `a lone mark under a declaration is read by the directive`(row: ContradictedAmount) throws {
        let text = "\(row.directive)\n\n2024-01-01 rent\n    expenses:rent    \(row.amount)\n    assets:bank"
        #expect(try DecimalMarkDirectiveTests.quantities(in: text) == [row.quantity, -row.quantity])
    }

    /// An entry rebuilt in such a file writes the figure the directive read,
    /// in the style the directive reads it by: the twelve hundred and fifty
    /// that `€12.50` was read as comes back `€1250`, which reads as the same
    /// figure under the declaration. The untouched entry keeps its text.
    @Test
    func `a rebuilt amount in such a file is written as the figure it was read as`() throws {
        var journal = try JournalParser().parse("""
        decimal-mark ,

        2024-01-01 rent
            expenses:rent    €12.50
            assets:bank     €-12.50

        2024-01-02 rent again
            expenses:rent    €12.50
            assets:bank     €-12.50
        """)
        let rent = try #require(journal.transactions.first)
        let renamed = try Transaction(
            id: rent.id, date: rent.date, description: "rent (revised)", postings: rent.postings,
        )
        let replaced = journal.replace(.transaction(rent), with: .transaction(renamed))
        #expect(replaced)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains(" €1250\n"))
        #expect(written.contains(" €12.50\n"))
        #expect(try DecimalMarkDirectiveTests.quantities(in: written) == [1250, -1250, 1250, -1250])
    }

    /// A sample with one mark is read like any other amount, by the tie-break
    /// where nothing is declared above it, and declares the mark it was read
    /// with: `D 1.000 EUR` is one euro to three places and declares the
    /// point, so `12,50 EUR` below it is twelve hundred and fifty, as hledger
    /// reads it. It used to declare the three places and no mark at all.
    @Test(arguments: ["D 1.000 EUR", "commodity 1.000 EUR"])
    func `a lone-mark sample declares the mark it was read with`(directive: String) throws {
        let journal = try JournalParser().parse("""
        \(directive)

        2024-01-01 rent
            expenses:rent    12,50 EUR
            assets:bank     -12,50 EUR
        """)
        #expect(journal.transactions.first?.postings.map(\.amount.quantity) == [1250, -1250])
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ".")
    }

    /// One amount with a lone mark under the declaration above it, and the
    /// figure hledger 1.52.4 reads it as.
    struct ContradictedAmount {
        var directive: String
        var amount: String
        var quantity: Decimal
    }

    static let contradictedAmounts: [ContradictedAmount] = [
        ContradictedAmount(directive: "decimal-mark ,", amount: "€12.50", quantity: 1250),
        ContradictedAmount(directive: "decimal-mark ,", amount: "€12.5", quantity: 125),
        ContradictedAmount(directive: "decimal-mark ,", amount: "€12.5000", quantity: 125_000),
        ContradictedAmount(directive: "decimal-mark ,", amount: "€0.5", quantity: 5),
        ContradictedAmount(directive: "decimal-mark .", amount: "€0,500", quantity: 500),
        ContradictedAmount(directive: "commodity $1,000.00", amount: "$1,50", quantity: 150),
        ContradictedAmount(directive: "D €1.000,00", amount: "$12.50", quantity: 1250),
        ContradictedAmount(directive: "decimal-mark ,", amount: "€5.", quantity: 5),
        ContradictedAmount(directive: "decimal-mark .", amount: "EUR 5,", quantity: 5),
    ]
}
