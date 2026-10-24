import Foundation
@testable import SwiftLedger
import Testing

/// `Ledger.checkBalanceAssertions()` replays a journal the way hledger checks
/// it while reading, and reports what hledger would have refused the file
/// over. Every case here was run through hledger 1.52.4 first. Issue #42.
@Suite("balance assertion check") struct BalanceAssertionCheckTests {
    private static func failures(_ text: String) throws -> [BalanceAssertionFailure] {
        try Ledger(journal: JournalParser().parse(text)).checkBalanceAssertions()
    }

    @Test
    func `the issue's journal fails at the rent posting`() throws {
        let failures = try Self.failures("""
        2024-01-01 Opening
            Assets:Checking    $100.00
            Equity:Opening

        2024-01-02 Rent
            Expenses:Rent      $30.00
            Assets:Checking   $-30.00 = $50.00
        """)

        let failure = try #require(failures.first)
        #expect(failures.count == 1)
        #expect(failure.transaction.description == "Rent")
        #expect(failure.postingIndex == 1)
        #expect(failure.asserted == Amount(quantity: 50, commodity: "$", commodityIsPrefix: true))
        #expect(failure.actual == Amount(quantity: 70, commodity: "$", commodityIsPrefix: true))
    }

    /// Journals hledger loads, so their assertions all hold.
    @Test(arguments: [
        // `==` holds once the other commodity nets back to zero.
        "2024-01-01 a\n    A    $10\n    A    10 EUR\n    A    -10 EUR\n    B\n\n2024-01-02 b\n    A    $0 == $10",
        // `=` leaves the subaccounts out and `=*` counts them.
        "2024-01-01 a\n    A:X    $10\n    A    $5\n    B\n\n2024-01-02 b\n    A    $0 = $5\n    A    $0 =* $15",
        // `==*` checks only the commodities the account itself has held.
        "2024-01-01 a\n    A:X    $10\n    A:Y   5 EUR\n    B\n\n2024-01-02 b\n    A    $0 ==* $10",
        // Entries are replayed by date, whatever order the file has them in.
        "2024-01-05 a\n    A    $10 = $15\n    B\n\n2024-01-01 b\n    A    $5\n    B",
        // Each assertion sees the postings up to itself, the same day's earlier entries included.
        "2024-01-01 a\n    A    $10 = $10\n    A    $5 = $15\n    B\n\n2024-01-01 b\n    A    $5 = $20\n    B",
        // Virtual postings move the balance too.
        "2024-01-01 a\n    A    $10\n    B\n    (A)    $5\n    [A]    $1\n    [C]   $-1\n\n"
            + "2024-01-02 b\n    A    $0 = $16",
        // A cost plays no part, and a commodity the account never held is zero.
        "2024-01-01 a\n    A    10 AAPL @ $5 = 10 AAPL\n    B\n\n2024-01-02 b\n    A    0 EUR = 0 EUR",
    ])
    func `an assertion hledger accepts holds`(text: String) throws {
        #expect(try Self.failures(text).isEmpty)
    }

    /// Journals hledger refuses, with the asserted and the actual amount its
    /// message names.
    @Test(arguments: zip([
        // `==` with a second commodity still held.
        "2024-01-01 a\n    A    $10\n    A    10 EUR\n    B\n\n2024-01-02 b\n    A    $0 == $10",
        // `=*` counts the subaccount.
        "2024-01-01 a\n    A:X    $10\n    A    $5\n    B\n\n2024-01-02 b\n    A    $0 =* $5",
        // `==*` on a commodity the account holds itself.
        "2024-01-01 a\n    A:X    $10\n    A   5 EUR\n    B\n\n2024-01-02 b\n    A    $0 ==* $10",
        // A back-dated entry later in the file counts before it.
        "2024-01-05 a\n    A    $10 = $10\n    B\n\n2024-01-01 b\n    A    $5\n    B",
        // A later posting of the same entry does not count yet.
        "2024-01-01 a\n    A    $10 = $15\n    A    $5\n    B",
        // Amounts are compared exactly, at no precision.
        "2024-01-01 a\n    A    $49.999\n    B\n\n2024-01-02 b\n    A    $0 = $50.00",
        // The secondary date plays no part in the order.
        "2024-01-05=2024-01-01 a\n    A    $10\n    B\n\n2024-01-02 b\n    A    $0 = $10",
    ], [
        "0 EUR / 10 EUR", "$5 / $15", "0 EUR / 5 EUR", "$10 / $15", "$15 / $10", "$50 / $49.999", "$10 / $0",
    ]))
    func `an assertion hledger refuses fails`(text: String, expected: String) throws {
        let failures = try Self.failures(text)
        #expect(failures.map { "\($0.asserted) / \($0.actual)" } == [expected])
    }
}
