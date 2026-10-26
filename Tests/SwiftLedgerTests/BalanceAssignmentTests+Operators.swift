import Foundation
@testable import SwiftLedger
import Testing

/// The `==`, `=*` and `==*` forms of a balance assignment, and what an
/// assignment posts when it moves nothing, ignores a cost, or is virtual.
/// Kept apart from the plain `=` cases so that neither file outgrows the
/// length SwiftLint allows a type.
extension BalanceAssignmentTests {
    static func dollars(_ quantity: Decimal) -> Amount {
        Amount(quantity: quantity, commodity: "$", commodityIsPrefix: true)
    }

    @Test
    func `a total assignment zeroes the other commodities the account holds`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Opening
            Assets:Checking    $10
            Assets:Checking    5 EUR
            Equity:Opening

        2024-01-02 Pay
            Assets:Checking    == $15
            Income:Salary

        """)
        let pay = try #require(journal.transactions.last)
        #expect(pay.postings.map(\.accountName) == [
            "Assets:Checking", "Assets:Checking", "Income:Salary", "Income:Salary",
        ])
        #expect(pay.postings.map(\.amount) == [
            Amount(quantity: 5, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -5, commodity: "EUR"),
            Amount(quantity: -5, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: 5, commodity: "EUR"),
        ])
        // The assertion sits on the last leg, where hledger prints it and
        // where the check sees both amounts the line moved.
        #expect(pay.postings.map(\.balanceAssertion) == [nil, Self.dollars(15), nil, nil])
        #expect(pay.postings[1].balanceAssertionOperator == .total)
        #expect(Ledger(journal: journal).checkBalanceAssertions().isEmpty)
    }

    @Test
    func `a total assignment that moves only another commodity`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Opening
            Assets:Checking    $15
            Assets:Checking    5 EUR
            Equity:Opening

        2024-01-02 Pay
            Assets:Checking    == $15
            Income:Salary

        """)
        let pay = try #require(journal.transactions.last)
        let euros = { (quantity: Decimal) in Amount(quantity: quantity, commodity: "EUR") }
        #expect(pay.postings.map(\.amount) == [euros(-5), euros(5)])
        #expect(pay.postings.first?.balanceAssertion == Self.dollars(15))
    }

    /// hledger measures an inclusive assignment against the subtree but keeps
    /// only what the account itself holds in other commodities, so `=*` also
    /// clears a commodity held by a subaccount alone.
    @Test
    func `an inclusive assignment counts the subaccounts`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Opening
            Assets:Checking        $10
            Assets:Checking:Sub    $7
            Assets:Checking:Sub    3 GBP
            Equity:Opening

        2024-01-02 Pay
            Assets:Checking    =* $20
            Income:Salary

        """)
        let pay = try #require(journal.transactions.last)
        let pounds = { (quantity: Decimal) in Amount(quantity: quantity, commodity: "GBP") }
        #expect(pay.postings.map(\.amount) == [Self.dollars(3), pounds(-3), Self.dollars(-3), pounds(3)])
        #expect(pay.postings.map(\.balanceAssertionOperator) == [.single, .singleInclusive, .single, .single])
    }

    @Test
    func `a total inclusive assignment zeroes a commodity only a subaccount holds`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Opening
            Assets:Checking        $10
            Assets:Checking:Sub    5 EUR
            Equity:Opening

        2024-01-02 Pay
            Assets:Checking    ==* $20
            Income:Salary

        """)
        let pay = try #require(journal.transactions.last)
        #expect(pay.postings.map(\.amount) == [
            Amount(quantity: 10, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -5, commodity: "EUR"),
            Amount(quantity: -10, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: 5, commodity: "EUR"),
        ])
    }

    @Test
    func `an assignment that moves nothing is a zero with no commodity`() throws {
        let journal = try JournalParser().parse(Self.opening + """
        2024-01-02 Check
            Assets:Checking    = $10
            Income:Salary

        """)
        let check = try #require(journal.transactions.last)
        let zero = Amount(quantity: 0, commodity: "")
        #expect(check.postings.map(\.amount) == [zero, zero])
    }

    @Test
    func `an assignment ignores costs`() throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Buy
            Assets:Broker      10 AAPL @ $5
            Assets:Checking

        2024-01-02 Fix
            Assets:Checking    = $0
            Equity:Adjust

        """)
        #expect(Self.quantities(journal, "Fix") == [50, -50])
    }

    /// A parenthesised posting balances nothing, so the elided one beside the
    /// assignment reads as zero, as it does in hledger; a bracketed one takes
    /// the remainder of its own group.
    @Test(arguments: [("(", ")", Posting.Kind.virtual, Decimal(0)), ("[", "]", .balancedVirtual, -5)])
    func `a virtual assignment is read from the postings of its kind`(
        open: String, close: String, kind: Posting.Kind, other: Decimal,
    ) throws {
        let journal = try JournalParser().parse("""
        2024-01-01 Opening
            \(open)Assets:Checking\(close)    $10
            \(open)Equity:Opening\(close)

        2024-01-02 Pay
            \(open)Assets:Checking\(close)    = $15
            \(open)Income:Salary\(close)

        """)
        let pay = try #require(journal.transactions.last)
        #expect(pay.postings.map(\.amount.quantity) == [5, other])
        #expect(pay.postings.map(\.kind) == [kind, kind])
    }
}
