import Foundation
@testable import SwiftLedger
import Testing

/// A commodity is written on the posting line verbatim, after or in front of
/// the number, and so is the commodity of a price or a balance assertion. A
/// line break in any of them ends the posting line early, the next parse reads
/// the rest as a new line, and the journal SwiftLedger has just written stops
/// loading. Issue #49.
@Suite("line breaks in a commodity") struct CommodityLineBreakTests {
    /// The commodities a posting line writes, each placed so that it is the
    /// first broken field `init` meets, with the path the error names.
    enum Field: CaseIterable {
        case suffixAmount
        case prefixAmount
        case price
        case balanceAssertion

        var path: String {
            switch self {
            case .suffixAmount, .prefixAmount: "postings[0].amount.commodity"
            case .price: "postings[0].price.amount.commodity"
            case .balanceAssertion: "postings[1].balanceAssertion.commodity"
            }
        }

        func postings(lineBreak: String) -> [Posting] {
            let dollars = Amount(quantity: -1500, commodity: "$", commodityIsPrefix: true)
            switch self {
            case .suffixAmount, .prefixAmount:
                let amount = self == .prefixAmount
                    ? Amount(quantity: 1200, commodity: "$\(lineBreak)", commodityIsPrefix: true)
                    : Amount(quantity: 1200, commodity: "USD\(lineBreak)")
                return [
                    Posting(accountName: "Expenses:Rent", amount: amount),
                    Posting(accountName: "Assets:Checking", amount: amount.negated),
                ]
            case .price:
                let price = Amount(quantity: 150, commodity: "$\(lineBreak)", commodityIsPrefix: true)
                return [
                    Posting(
                        accountName: "Assets:Brokerage",
                        amount: Amount(quantity: 10, commodity: "AAPL"),
                        price: .perUnit(price),
                    ),
                    Posting(accountName: "Assets:Checking", amount: dollars),
                ]
            case .balanceAssertion:
                return [
                    Posting(accountName: "Expenses:Rent", amount: dollars.negated),
                    Posting(
                        accountName: "Assets:Checking",
                        amount: dollars,
                        balanceAssertion: Amount(quantity: 0, commodity: "USD\(lineBreak)"),
                    ),
                ]
            }
        }
    }

    @Test(arguments: Field.allCases, ["\n", "\r", "\r\n"])
    func `a commodity a posting line writes refuses a line break`(field: Field, lineBreak: String) {
        #expect(throws: LedgerError.lineBreakInField(field.path)) {
            try Transaction(
                date: JournalDate(year: 2026, month: 7, day: 1),
                description: "Rent",
                postings: field.postings(lineBreak: lineBreak),
            )
        }
    }

    /// A `\r` stranded behind a suffix commodity used to load as part of the
    /// symbol, so `USD\r` was a commodity of its own and the entry balanced in
    /// two currencies nobody wrote. hledger reads past the `\r`; SwiftLedger
    /// refuses the file instead, the choice it already makes for a `\r`
    /// behind the number (`amount-stray-cr`), since only the `\r` that ends a
    /// line is a line ending.
    @Test
    func `a parsed commodity holding a stray carriage return refuses to load`() throws {
        let text = "2026-07-01 Rent\n    Expenses:Rent  5 USD\r  ; note\n    Assets:Checking  -5 USD\n"
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .lineBreakInField("postings[0].amount.commodity"))
    }

    /// A transaction decoded from JSON goes through `init`, so a commodity
    /// edited into a document by hand is refused by the same check.
    @Test
    func `a decoded transaction refuses a line break in a commodity`() throws {
        let clean = try Transaction(
            date: JournalDate(year: 2026, month: 7, day: 1),
            description: "Rent",
            postings: Field.suffixAmount.postings(lineBreak: ""),
        )
        let json = try #require(String(data: JSONEncoder().encode(clean), encoding: .utf8))
        let broken = json.replacingOccurrences(of: #""commodity":"USD""#, with: #""commodity":"USD\n""#)
        #expect(broken != json)
        #expect(throws: LedgerError.lineBreakInField("postings[0].amount.commodity")) {
            try JSONDecoder().decode(Transaction.self, from: Data(broken.utf8))
        }
    }
}
