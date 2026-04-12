import Foundation

/// A balance sheet snapshot at a specific point in time.
///
/// Verifies the fundamental accounting equation: **Assets = Liabilities + Equity**
public struct BalanceSheet: Sendable, Codable {
    public let date: Date
    public let currency: CurrencyCode

    public let assets: [AccountBalance]
    public let liabilities: [AccountBalance]
    public let equity: [AccountBalance]

    public var totalAssets: Money {
        sum(balances: assets)
    }

    public var totalLiabilities: Money {
        sum(balances: liabilities)
    }

    public var totalEquity: Money {
        sum(balances: equity)
    }

    public var totalLiabilitiesAndEquity: Money {
        Money(totalLiabilities.amount + totalEquity.amount, currency)
    }

    /// `true` when Assets = Liabilities + Equity (the accounting equation holds).
    public var isBalanced: Bool {
        totalAssets.amount == totalLiabilitiesAndEquity.amount
    }

    // MARK: - Init

    /// Generates a balance sheet from a ledger at the current date.
    public init(ledger: Ledger, date: Date = Date(), currency: CurrencyCode) {
        self.date = date
        self.currency = currency.uppercased()

        let balances = ledger.allBalances().filter { $0.account.currency == currency.uppercased() }
        self.assets      = balances.filter { $0.account.type == .asset }
        self.liabilities = balances.filter { $0.account.type == .liability }
        self.equity      = balances.filter { $0.account.type == .equity }
    }

    // MARK: - Private

    private func sum(balances: [AccountBalance]) -> Money {
        let total = balances.reduce(Decimal.zero) { $0 + $1.netBalance.amount }
        return Money(total, currency)
    }
}
