import Foundation
@testable import SwiftLedger
import Testing

/// An indented `D`, `commodity` or `decimal-mark` line under a `commodity` or
/// an `account` block is a subdirective hledger skips, and the parser used to
/// read it for what it declared: `  decimal-mark ,` under `commodity €` made
/// `€1.000` below the block a thousand where hledger reads one euro, and
/// `  D $1,000.00` under an account declaration put every bare number below
/// it in dollars where hledger leaves it bare (issue #105). Only an indented
/// `format` line declares anything now. hledger 1.52.4's readings are pinned
/// in `indented-decimal-mark-under-block.journal` and
/// `indented-default-under-account.journal`.
@Suite("indented declarations under a block") struct IndentedDeclarationTests {
    /// The journal from the issue, the same line with text after the comma,
    /// and a `D` and a `commodity` sample: none declares anything, so the
    /// thousand is one euro to three places, read with the point, and every
    /// line goes back as it came.
    @Test(arguments: ["  decimal-mark ,", "  decimal-mark , x", "\tD €1.000,00", "  commodity €1.000,00"])
    func `an indented declaration under a commodity block declares nothing`(subdirective: String) throws {
        let text = "commodity €\n\(subdirective)\n\n2024-01-01 Salary\n    Assets:Checking  €1.000\n    Income:Salary\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.map(\.amount.quantity) == [1, -1])
        #expect(journal.commodityFormats["€"]?.decimalMark == ".")
        #expect(journal.directives == ["commodity €", subdirective])
    }

    /// Under an account declaration, an indented `D` line names no default
    /// commodity and declares no mark: the bare number stays bare, and
    /// `12,50` is twelve and a half rather than the twelve hundred and fifty
    /// a declared point made of it.
    @Test
    func `an indented D line under an account block names no default commodity`() throws {
        let journal = try JournalParser().parse("""
        account Assets:Checking
          D $1,000.00

        2024-01-01 Lunch
            Expenses:Food    25.00
            Assets:Checking

        2024-01-02 Coffee
            Expenses:Food    12,50
            Assets:Checking
        """)
        let amounts = journal.transactions.compactMap { $0.postings.first?.amount }
        let half = try #require(Decimal(string: "12.5"))
        #expect(amounts == [Amount(quantity: 25, commodity: ""), Amount(quantity: half, commodity: "")])
        #expect(journal.commodityFormats["$"] == nil)
    }
}
