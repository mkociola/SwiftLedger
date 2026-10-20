import Foundation
@testable import SwiftLedger
import Testing

/// Where nothing is declared, a lone mark with exactly three digits after it
/// used to be settled by ledger-cli's tie-break, `,` grouping and `.`
/// dividing, where hledger reads it as the decimal mark either way (issue
/// #83). hledger is the reference, so the parser now reads it as hledger
/// does, and a sample with that shape declares the mark it was read with;
/// `RenderedMarkTests` covers what the serializer writes. Each reading
/// below is hledger 1.52.4's, pinned in
/// `undeclared-lone-mark.journal` and `default-commodity-lone-mark-sample.journal`.
@Suite("an undeclared lone mark") struct UndeclaredLoneMarkTests {
    /// One amount with nothing declared above it, and the figure hledger
    /// reads it as.
    struct Undeclared {
        var amount: String
        var quantity: Decimal
    }

    static let undeclared: [Undeclared] = [
        Undeclared(amount: "$1,000", quantity: Decimal(string: "1.000")!),
        Undeclared(amount: "$1.000", quantity: Decimal(string: "1.000")!),
        Undeclared(amount: "$12,345", quantity: Decimal(string: "12.345")!),
        Undeclared(amount: "$1,0000", quantity: Decimal(string: "1.0000")!),
        Undeclared(amount: "$0,500", quantity: Decimal(string: "0.500")!),
        Undeclared(amount: "$1,000,000", quantity: 1_000_000),
        Undeclared(amount: "$1.000,", quantity: 1000),
        Undeclared(amount: "$1,000.00", quantity: 1000),
    ]

    /// A lone mark divides whatever follows it, three digits included, and
    /// the other shapes read as they did.
    @Test(arguments: UndeclaredLoneMarkTests.undeclared)
    func `a lone mark with three digits after it is the decimal mark`(row: Undeclared) throws {
        let text = "2024-01-01 rent\n    expenses:rent    \(row.amount)\n    assets:bank"
        #expect(try DecimalMarkDirectiveTests.quantities(in: text) == [row.quantity, -row.quantity])
    }

    /// The one undeclared shape still refused: a leading comma with three
    /// digits after it, which hledger reads as a commodity called `€,`
    /// holding five hundred. Refusing it is the lesser error, as before.
    @Test
    func `a leading comma before three digits is still refused`() {
        let text = "2024-01-01 rent\n    expenses:rent    €,500\n    assets:bank"
        #expect(throws: LedgerError.self) { try JournalParser().parse(text) }
    }

    /// A sample with that shape is read the same way, so `D 1,000 EUR`
    /// declares the comma, as it does in hledger: `12.50 EUR` below it is
    /// twelve hundred and fifty and `1,500 EUR` is one and a half. It used to
    /// declare the point, and every amount below it followed the wrong mark.
    @Test(arguments: ["D 1,000 EUR", "commodity 1,000 EUR", "commodity EUR\n    format 1,000 EUR"])
    func `a lone-mark sample with three digits declares the mark it was read with`(directive: String) throws {
        let journal = try JournalParser().parse("""
        \(directive)

        2024-01-01 against the declaration
            expenses:rent    12.50 EUR
            assets:bank     -12.50 EUR

        2024-01-02 with it
            expenses:rent    1,500 EUR
            assets:bank     -1,500 EUR
        """)
        let quantities = journal.transactions.flatMap { $0.postings.map(\.amount.quantity) }
        #expect(quantities == [1250, -1250, Decimal(string: "1.5"), Decimal(string: "-1.5")])
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")
        #expect(journal.commodityFormats["EUR"]?.fractionDigits == 3)
    }

    /// Read as the decimal mark, the shape says which mark the file divides
    /// with, and votes like any other amount: it used to abstain.
    @Test
    func `an amount in that shape votes on the file's marks`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 rent
            expenses:rent    $1,000
            assets:bank     $-1,000

        2024-01-02 fees
            expenses:fees    $2,500
            assets:bank     $-2,500
        """)
        #expect(journal.commodityFormats["$"]?.decimalMark == ",")
        #expect(journal.commodityFormats["$"]?.fractionDigits == 3)
        #expect(journal.commodityFormats["$"]?.groupsThousands == false)
    }
}
