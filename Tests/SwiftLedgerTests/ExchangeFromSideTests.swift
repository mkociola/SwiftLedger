import Foundation
@testable import SwiftLedger
import Testing

/// Which of an exchange's two commodities is its `from` side when one of them
/// first appears on a priced posting that later cancels. hledger 1.52.4 hangs
/// the inferred cost on the commodity of the first posting in either of the
/// two, priced or not, so the verdict has to name the same one.
@Suite("exchange from side") struct ExchangeFromSideTests {
    private static let rate = PostingPrice.perUnit(Amount(quantity: Decimal(string: "1.1") ?? .nan, commodity: "USD"))

    private static func posting(_ quantity: Decimal, _ commodity: String, price: PostingPrice? = nil) -> Posting {
        Posting(accountName: "Assets:Any", amount: Amount(quantity: quantity, commodity: commodity), price: price)
    }

    @Test
    func `the from side is the commodity a cancelling priced posting writes first`() {
        let verdict = Transaction.balance(of: [
            Self.posting(10, "EUR", price: Self.rate),
            Self.posting(-10, "EUR", price: Self.rate),
            Self.posting(-110, "USD"),
            Self.posting(100, "EUR"),
        ])
        #expect(verdict.real == .exchange(
            from: Amount(quantity: 100, commodity: "EUR"), to: Amount(quantity: -110, commodity: "USD"),
        ))
    }

    @Test
    func `a cancelling total-priced pair names the from side too`() {
        let total = PostingPrice.total(Amount(quantity: 11, commodity: "USD"))
        let verdict = Transaction.balance(of: [
            Self.posting(10, "EUR", price: total),
            Self.posting(-10, "EUR", price: total),
            Self.posting(-110, "USD"),
            Self.posting(100, "EUR"),
        ])
        #expect(verdict.real == .exchange(
            from: Amount(quantity: 100, commodity: "EUR"), to: Amount(quantity: -110, commodity: "USD"),
        ))
    }

    @Test
    func `an unpriced posting written first still names the from side`() {
        let verdict = Transaction.balance(of: [
            Self.posting(-110, "USD"),
            Self.posting(10, "EUR", price: Self.rate),
            Self.posting(-10, "EUR", price: Self.rate),
            Self.posting(100, "EUR"),
        ])
        #expect(verdict.real == .exchange(
            from: Amount(quantity: -110, commodity: "USD"), to: Amount(quantity: 100, commodity: "EUR"),
        ))
    }
}
