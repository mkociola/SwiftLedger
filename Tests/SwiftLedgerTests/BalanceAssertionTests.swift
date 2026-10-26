import Foundation
@testable import SwiftLedger
import Testing

/// hledger writes four balance assertions, and each one asks a different
/// question of the account: `=` its own balance in one commodity, `==` that
/// commodity alone, and `=*` and `==*` the same with its subaccounts counted.
/// Reading `==` as `=` wrote a weaker promise back than the user made.
/// Issue #42.
@Suite("balance assertion operators") struct BalanceAssertionTests {
    @Test(arguments: [
        ("=", BalanceAssertionOperator.single),
        ("==", .total),
        ("=*", .singleInclusive),
        ("==*", .totalInclusive),
    ])
    func `each operator is read and written back as it was written`(
        written: String, expected: BalanceAssertionOperator,
    ) throws {
        let text = """
        2024-01-01 Opening
            Assets:Checking    $100.00 \(written) $100.00
            Equity:Opening

        """
        let journal = try JournalParser().parse(text)

        let posting = try #require(journal.transactions.first?.postings.first)
        #expect(posting.balanceAssertionOperator == expected)
        #expect(posting.balanceAssertion?.quantity == 100)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `an operator after a price is read and written back`() throws {
        let text = """
        2024-01-01 Shares
            Assets:Brokerage    10 AAPL @ $5.00 ==* 10 AAPL
            Assets:Checking

        """
        let journal = try JournalParser().parse(text)

        #expect(journal.transactions.first?.postings.first?.balanceAssertionOperator == .totalInclusive)
        #expect(JournalSerializer().serialize(journal).contains("10 AAPL @ $5.00 ==* 10 AAPL\n"))
    }

    /// A `==` assignment that clears a second commodity becomes two postings,
    /// and only the last, which carries the assertion, carries its operator.
    @Test
    func `a posting that asserts nothing has the plain operator`() throws {
        let text = """
        2024-01-01 Opening
            Assets:Checking    $10.00
            Assets:Checking    5 EUR
            Equity:Opening

        2024-01-02 Statement
            Assets:Checking    == $15.00
            Income:Salary

        """
        let postings = try JournalParser().parse(text).transactions.last?.postings ?? []

        #expect(postings.map(\.balanceAssertionOperator) == [.single, .total, .single, .single])
        #expect(Posting(accountName: "A", amount: Amount(quantity: 1, commodity: "$"), balanceAssertionOperator: .total)
            .balanceAssertionOperator == .single)
    }

    @Test
    func `a star after a space is not part of the operator`() {
        let text = """
        2024-01-01 Opening
            Assets:Checking    $100.00 = *$100.00
            Equity:Opening

        """
        #expect(throws: (any Error).self) { try JournalParser().parse(text) }
    }

    /// JSON written before the operator was modelled has no key for it, and
    /// every assertion it holds was read as `=`.
    @Test
    func `a posting decoded without an operator asserts one commodity`() throws {
        let json = """
        {"accountName": "Assets:Checking", "amount": {"quantity": 0, "commodity": "$", "commodityIsPrefix": true},
         "balanceAssertion": {"quantity": 5, "commodity": "$", "commodityIsPrefix": true}}
        """
        let posting = try JSONDecoder().decode(Posting.self, from: Data(json.utf8))
        #expect(posting.balanceAssertionOperator == .single)
    }
}
