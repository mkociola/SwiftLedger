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
    /// The same for a mark with nothing after it: `€5.` under `decimal-mark ,`
    /// is five, here and in hledger, rather than a group mark with nothing to
    /// its right, which would be no number at all.
    @Test(arguments: [("decimal-mark ,", "€5."), ("decimal-mark .", "EUR 5,")])
    func `a trailing mark divides under either declaration`(directive: String, amount: String) throws {
        let text = "\(directive)\n\n2024-01-01 rent\n    expenses:rent    \(amount)\n    assets:bank"
        #expect(try DecimalMarkDirectiveTests.quantities(in: text) == [5, -5])
    }

    /// Under a declaration, hledger reads a lone mark by the directive rather
    /// than by the number: the declared mark divides, and any other mark
    /// groups whatever digits sit after it, so `€12.50` under `decimal-mark ,`
    /// is twelve hundred and fifty. The two rules a number settles itself by
    /// where nothing is declared, that a mark with anything but three digits
    /// after it divides and that nothing groups a zero, are not consulted
    /// under one. Such an amount is most likely a typo, and reading it as the
    /// number says loads a figure a hundred times apart from hledger's.
    @Test(arguments: contradictedAmounts)
    func `a lone mark that is not the declared mark groups whatever follows it`(row: ContradictedAmount) throws {
        let text = "\(row.directive)\n\n2024-01-01 rent\n    expenses:rent    \(row.amount)\n    assets:bank"
        #expect(try DecimalMarkDirectiveTests.quantities(in: text) == [row.quantity, -row.quantity])
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
}

/// One amount written against the declaration above it, and the figure
/// hledger 1.52.4 reads it as.
struct ContradictedAmount {
    var directive: String
    var amount: String
    var quantity: Decimal
}

let contradictedAmounts: [ContradictedAmount] = [
    ContradictedAmount(directive: "decimal-mark ,", amount: "€12.50", quantity: 1250),
    ContradictedAmount(directive: "decimal-mark ,", amount: "€12.5", quantity: 125),
    ContradictedAmount(directive: "decimal-mark ,", amount: "€12.5000", quantity: 125_000),
    ContradictedAmount(directive: "decimal-mark ,", amount: "€0.5", quantity: 5),
    ContradictedAmount(directive: "decimal-mark .", amount: "€0,500", quantity: 500),
    ContradictedAmount(directive: "commodity $1,000.00", amount: "$1,50", quantity: 150),
    ContradictedAmount(directive: "D €1.000,00", amount: "$12.50", quantity: 1250),
]
