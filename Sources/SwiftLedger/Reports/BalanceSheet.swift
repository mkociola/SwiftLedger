import Foundation

/// A balance sheet snapshot at a specific point in time.
///
/// Verifies the fundamental accounting equation:
/// **Assets = Liabilities + Equity + Net Income**
///
/// Net income (Revenue − Expenses) is included because until the books are
/// formally closed, revenue and expense balances are not yet rolled into equity.
/// If the ledger uses period-end closing entries, `netIncome` will be zero and
/// the classic `Assets = Liabilities + Equity` equation holds.
public struct BalanceSheet: Sendable, Codable {
    public let date: Date
    public let currency: CurrencyCode

    public let assets: [AccountBalance]
    public let liabilities: [AccountBalance]
    public let equity: [AccountBalance]
    /// Revenue and expense balances as of `date` (used to compute `netIncome`).
    public let revenues: [AccountBalance]
    public let expenses: [AccountBalance]

    public var totalAssets: Money {
        sum(balances: assets)
    }

    public var totalLiabilities: Money {
        sum(balances: liabilities)
    }

    public var totalEquity: Money {
        sum(balances: equity)
    }

    /// Current-period net income (Revenue − Expenses). Zero on closed books.
    public var netIncome: Money {
        Money(
            revenues.reduce(Decimal.zero) { $0 + $1.netBalance.amount }
            - expenses.reduce(Decimal.zero) { $0 + $1.netBalance.amount },
            currency
        )
    }

    /// Total of liabilities, equity, and current-period net income.
    public var totalLiabilitiesAndEquity: Money {
        Money(totalLiabilities.amount + totalEquity.amount + netIncome.amount, currency)
    }

    /// `true` when Assets = Liabilities + Equity + Net Income.
    public var isBalanced: Bool {
        totalAssets.amount == totalLiabilitiesAndEquity.amount
    }

    // MARK: - Init

    /// Generates a balance sheet from a ledger as of the given date.
    public init(ledger: Ledger, date: Date = Date(), currency: CurrencyCode) {
        self.date = date
        self.currency = currency.uppercased()

        let balances = ledger.allBalances(asOf: date).filter { $0.account.currency == currency.uppercased() }
        self.assets      = balances.filter { $0.account.type == .asset }
        self.liabilities = balances.filter { $0.account.type == .liability }
        self.equity      = balances.filter { $0.account.type == .equity }
        self.revenues    = balances.filter { $0.account.type == .revenue }
        self.expenses    = balances.filter { $0.account.type == .expense }
    }

    // MARK: - Private

    private func sum(balances: [AccountBalance]) -> Money {
        let total = balances.reduce(Decimal.zero) { $0 + $1.netBalance.amount }
        return Money(total, currency)
    }
}
