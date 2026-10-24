/// An income statement (profit & loss) for a date range, counting each
/// posting on its own date, `Posting.date` or else its transaction's.
public struct IncomeStatement: Sendable {
    public let from: JournalDate?
    // swiftlint:disable:next identifier_name
    public let to: JournalDate?
    public let revenues: [AccountBalance]
    public let expenses: [AccountBalance]

    // swiftlint:disable:next identifier_name
    public init(ledger: Ledger, from: JournalDate? = nil, to: JournalDate? = nil) {
        self.from = from
        self.to = to

        let postings = ledger.postingsByDate(from: from, to: to).map { $0.transaction.postings[$0.index] }
        let accounts = ledger.accounts

        func balances(for type: AccountType) -> [AccountBalance] {
            accounts
                .filter { $0.type == type }
                .compactMap { acc -> AccountBalance? in
                    let amounts = postings
                        .filter { $0.accountName == acc.name }
                        .map(\.amount)
                        .netByCommodity()
                        .filter { !$0.isZero }
                    guard !amounts.isEmpty else { return nil }
                    return AccountBalance(account: acc, amounts: amounts)
                }
        }

        revenues = balances(for: .revenue)
        expenses = balances(for: .expense)
    }

    /// Net income (revenues – expenses) per commodity.
    public var netIncome: [Amount] {
        let rev = revenues.flatMap(\.amounts)
        let exp = expenses.flatMap(\.amounts)
        return (rev + exp).netByCommodity()
    }
}
