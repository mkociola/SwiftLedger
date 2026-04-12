import Foundation

/// A profit-and-loss statement for a specific period.
///
/// `netIncome = totalRevenue - totalExpenses`
public struct IncomeStatement: Sendable, Codable {
    public let periodStart: Date
    public let periodEnd: Date
    public let currency: CurrencyCode

    public let revenues: [AccountBalance]
    public let expenses: [AccountBalance]

    public var totalRevenue: Money {
        sum(balances: revenues)
    }

    public var totalExpenses: Money {
        sum(balances: expenses)
    }

    /// Net income (positive) or net loss (negative).
    public var netIncome: Money {
        Money(totalRevenue.amount - totalExpenses.amount, currency)
    }

    public var isProfit: Bool { netIncome.amount >= .zero }

    // MARK: - Init

    /// Generates an income statement from a ledger for the given period.
    public init(ledger: Ledger, from start: Date, to end: Date, currency: CurrencyCode) {
        self.periodStart = start
        self.periodEnd = end
        self.currency = currency.uppercased()

        // Only consider transactions within the period.
        let periodTxns = ledger.journal.transactions.filter { $0.date >= start && $0.date <= end }

        // Build a temporary ledger slice for the period.
        var periodBalances: [UUID: (debit: Decimal, credit: Decimal)] = [:]
        for tx in periodTxns {
            for entry in tx.entries {
                let id = entry.account.id
                var pair = periodBalances[id] ?? (0, 0)
                if entry.side == .debit { pair.debit += entry.amount.amount }
                else { pair.credit += entry.amount.amount }
                periodBalances[id] = pair
            }
        }

        let allAccounts = ledger.chartOfAccounts.all
            .filter { $0.currency == currency.uppercased() }

        func makeBalance(_ account: Account) -> AccountBalance {
            let pair = periodBalances[account.id] ?? (0, 0)
            return AccountBalance(
                account: account,
                debitTotal: Money(pair.debit, currency),
                creditTotal: Money(pair.credit, currency)
            )
        }

        self.revenues = allAccounts.filter { $0.type == .revenue }.map(makeBalance)
        self.expenses = allAccounts.filter { $0.type == .expense }.map(makeBalance)
    }

    // MARK: - Private

    private func sum(balances: [AccountBalance]) -> Money {
        let total = balances.reduce(Decimal.zero) { $0 + $1.netBalance.amount }
        return Money(total, currency)
    }
}
