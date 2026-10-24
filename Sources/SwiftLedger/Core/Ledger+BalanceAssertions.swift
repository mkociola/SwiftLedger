import Foundation

/// A balance assertion the journal's own postings contradict.
public struct BalanceAssertionFailure: Sendable, Hashable {
    /// The entry the assertion is written in.
    public let transaction: Transaction
    /// Which of `transaction.postings` carries the assertion.
    public let postingIndex: Int
    /// What the assertion says the balance is, in one commodity. For a `==`
    /// or `==*` assertion that fails because the account still holds another
    /// commodity, this is zero in that commodity, as hledger reports it.
    public let asserted: Amount
    /// What the postings up to and including the asserting one add up to, in
    /// the same commodity.
    public let actual: Amount
}

public extension Ledger {
    /// Every balance assertion in the journal that its postings contradict,
    /// in the order they are checked.
    ///
    /// The check is hledger's: entries are replayed by date, entries of one
    /// day in file order, and the postings of an entry in the order written,
    /// so an assertion sees exactly the postings before it and itself. Every
    /// kind of posting counts, a cost plays no part, and amounts are compared
    /// exactly, so `$49.999` does not satisfy `= $50.00`. What each operator
    /// asks is described on `BalanceAssertionOperator`. For `==*`, as in
    /// hledger, the other commodities that have to be zero are the ones the
    /// account itself has held, so one held only by a subaccount is not
    /// checked.
    ///
    /// hledger refuses a file with a failing assertion. The parser does not,
    /// because an editor that cannot open the file cannot fix the line
    /// either; this is how the app finds out, and it decides what to do with
    /// the answer.
    func checkBalanceAssertions() -> [BalanceAssertionFailure] {
        var own: [String: CommoditySums] = [:]
        var failures: [BalanceAssertionFailure] = []
        for transaction in transactions() {
            for (index, posting) in transaction.postings.enumerated() {
                let account = posting.accountName
                Self.accumulate(posting.amount, into: &own[account, default: [:]])
                guard let asserted = posting.balanceAssertion else { continue }

                let kind = posting.balanceAssertionOperator
                let others = kind.isTotal ? (own[account] ?? [:]).filter { $0.key != asserted.commodity } : [:]
                let expected = [asserted] + Self.amounts(from: others).map { Amount(
                    quantity: .zero, commodity: $0.commodity, commodityIsPrefix: $0.commodityIsPrefix,
                ) }
                for amount in expected {
                    // ponytail: `=*` scans every account; keep running subtree sums if journals get huge.
                    let quantity = kind.isInclusive
                        ? own.filter { isInSubtree($0.key, prefix: account) }
                        .compactMap { $0.value[amount.commodity]?.quantity }.reduce(Decimal.zero, +)
                        : own[account]?[amount.commodity]?.quantity ?? .zero
                    guard quantity != amount.quantity else { continue }
                    failures.append(BalanceAssertionFailure(
                        transaction: transaction,
                        postingIndex: index,
                        asserted: amount,
                        actual: Amount(
                            quantity: quantity, commodity: amount.commodity,
                            commodityIsPrefix: amount.commodityIsPrefix,
                        ),
                    ))
                }
            }
        }
        return failures
    }
}
