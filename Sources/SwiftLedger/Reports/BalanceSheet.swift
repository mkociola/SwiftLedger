/// A balance sheet (statement of financial position) as of a given date.
///
/// Shows Assets, Liabilities, and Equity balances.
/// `isBalanced` sums the journal's own posting amounts at face value and
/// reports whether every commodity nets to zero; see the property for the
/// ordinary journals that answers `false`.
public struct BalanceSheet: Sendable {
    public let asOf: JournalDate
    public let assets: [AccountBalance]
    public let liabilities: [AccountBalance]
    public let equity: [AccountBalance]

    /// `true` when every commodity in the journal nets to zero across all
    /// postings at face value, parenthesised (unbalanced virtual) ones
    /// excluded.
    ///
    /// Face value is the claim, and it is deliberate: this is hledger's own
    /// `bal` total, which converts nothing. It folds `amount` rather than
    /// `balancingAmount`, so a journal holding an `@` price reads as
    /// unbalanced even though each of its entries balances at cost, and so
    /// does one holding an entry written in two commodities with no price at
    /// all, which balances by the cost the entry implies. Both are ordinary
    /// multi-currency bookkeeping, `Examples/sample.ledger` holds one of each,
    /// and neither is a fault in the journal: a book that records a currency
    /// exchange is not in balance commodity by commodity unless it also
    /// records the equity postings that hledger's `--infer-equity` would add.
    ///
    /// So this is not "the books add up". It is one `Bool` over the
    /// per-commodity nets, useful for the single-commodity journal it was
    /// written for; ask a transaction's own `balance` for whether an entry
    /// balances.
    ///
    /// It also skips parenthesised postings, which move money outside the
    /// double-entry books by design; bracketed ones net to zero per
    /// transaction and so cost nothing to include.
    public let isBalanced: Bool

    public init(ledger: Ledger, asOf: JournalDate? = nil) {
        let date = asOf ?? JournalDate.today
        self.asOf = date
        let balances = ledger.allBalances(asOf: date)
        let accounts = ledger.accounts

        func accountBalances(for type: AccountType) -> [AccountBalance] {
            accounts
                .filter { $0.type == type }
                .compactMap { acc -> AccountBalance? in
                    guard let amounts = balances[acc.name], !amounts.isEmpty else { return nil }
                    let nonZero = amounts.filter { !$0.isZero }
                    return nonZero.isEmpty ? nil : AccountBalance(account: acc, amounts: nonZero)
                }
        }

        assets = accountBalances(for: .asset)
        liabilities = accountBalances(for: .liability)
        equity = accountBalances(for: .equity)

        // Balance check: all raw posting amounts should net to zero per
        // commodity. Parenthesised (unbalanced virtual) postings move money
        // outside the double-entry books by design, so counting them would make
        // this false for every envelope-style journal. Bracketed postings net
        // to zero per transaction, so including them costs nothing.
        let allAmounts = ledger.journal.transactions
            .flatMap(\.postings)
            .filter { $0.kind != .virtual }
            .map(\.amount)
        let nets = allAmounts.netByCommodity()
        isBalanced = nets.allSatisfy(\.isZero)
    }
}
