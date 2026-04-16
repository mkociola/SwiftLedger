/// A balance sheet (statement of financial position) as of a given date.
///
/// Shows Assets, Liabilities, and Equity balances.
/// `isBalanced` is `true` when the sum of ALL raw account amounts equals zero,
/// which is always true for a well-formed double-entry journal.
public struct BalanceSheet: Sendable {
    public let asOf: JournalDate
    public let assets: [AccountBalance]
    public let liabilities: [AccountBalance]
    public let equity: [AccountBalance]

    /// `true` when the entire journal balances (sum of all postings = 0 per commodity).
    public let isBalanced: Bool

    public init(ledger: Ledger, asOf: JournalDate? = nil) {
        let date       = asOf ?? JournalDate.today
        self.asOf      = date
        let balances   = ledger.allBalances(asOf: date)
        let accounts   = ledger.accounts

        func accountBalances(for type: AccountType) -> [AccountBalance] {
            accounts
                .filter { $0.type == type }
                .compactMap { acc -> AccountBalance? in
                    guard let amounts = balances[acc.name], !amounts.isEmpty else { return nil }
                    let nonZero = amounts.filter { !$0.isZero }
                    return nonZero.isEmpty ? nil : AccountBalance(account: acc, amounts: nonZero)
                }
        }

        self.assets      = accountBalances(for: .asset)
        self.liabilities = accountBalances(for: .liability)
        self.equity      = accountBalances(for: .equity)

        // Balance check: all raw posting amounts should net to zero per commodity
        let allAmounts = ledger.journal.transactions
            .flatMap(\.postings)
            .map(\.amount)
        let nets = allAmounts.netByCommodity()
        self.isBalanced = nets.allSatisfy(\.isZero)
    }
}
