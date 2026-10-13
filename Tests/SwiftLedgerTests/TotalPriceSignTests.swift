import Foundation
@testable import SwiftLedger
import Testing

/// A total price keeps the sign it is written with and takes the sign of the
/// posting's quantity on top, the way hledger weighs it. Reading only the
/// quantity's sign loaded an entry hledger refuses and refused one it loads.
/// Issue #69.
@Suite("total price sign") struct TotalPriceSignTests {
    @Test
    func `a negative total price on a positive amount balances a positive cash leg`() throws {
        let text = """
        2026-10-10 Exchange
            Assets:Euros       100.00 EUR @@ -110.00 USD
            Assets:Checking    110.00 USD

        """
        let journal = try JournalParser().parse(text)

        #expect(journal.transactions.count == 1)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a negative total price on a positive amount does not balance a negative cash leg`() {
        let text = """
        2026-10-10 Exchange
            Assets:Euros       100.00 EUR @@ -110.00 USD
            Assets:Checking    -110.00 USD

        """
        #expect(throws: (any Error).self) { try JournalParser().parse(text) }
    }

    /// The quantity's sign multiplies the price's, so a negative total price
    /// on a negative amount costs a positive one, and on a zero amount it
    /// keeps its own sign.
    @Test(arguments: zip(["100", "-100", "0"], ["-110", "110", "-110"]))
    func `a total price costs its own sign times the quantity's`(quantity: String, expected: String) {
        let price = PostingPrice.total(Amount(quantity: -110, commodity: "USD"))
        #expect(price.cost(of: Decimal(string: quantity) ?? .nan).quantity == Decimal(string: expected))
    }
}
