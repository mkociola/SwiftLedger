/// An income statement (profit & loss) for a date range.
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

        let transactions = ledger.transactions(from: from, to: to)
        let accounts = ledger.accounts

        func balances(for type: AccountType) -> [AccountBalance] {
            accounts
                .filter { $0.type == type }
                .compactMap { acc -> AccountBalance? in
                    let amounts = transactions
                        .flatMap(\.postings)
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
