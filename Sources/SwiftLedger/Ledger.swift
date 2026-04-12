import Foundation

/// The top-level double-entry ledger.
///
/// `Ledger` combines a ``ChartOfAccounts`` and a ``Journal``. Use it to
/// register accounts, post transactions, and query balances or reports.
///
/// `Ledger` is a value type (`struct`). When used from concurrent contexts
/// wrap it in an `actor` or protect with your own synchronization.
public struct Ledger: Sendable, Codable, Hashable {
    public private(set) var chartOfAccounts: ChartOfAccounts
    public private(set) var journal: Journal

    public init() {
        self.chartOfAccounts = ChartOfAccounts()
        self.journal = Journal()
    }

    // MARK: - Account management

    /// Registers a new account.
    /// - Throws: `LedgerError.duplicateAccount` if already present.
    public mutating func addAccount(_ account: Account) throws {
        try chartOfAccounts.add(account)
    }

    // MARK: - Posting

    /// Validates and posts a transaction to the journal.
    ///
    /// All accounts referenced in the transaction's entries must already exist
    /// in the chart of accounts.
    ///
    /// - Throws: `LedgerError.accountNotFound` if an entry references an unknown account.
    public mutating func post(_ transaction: Transaction) throws {
        for entry in transaction.entries {
            _ = try chartOfAccounts.account(id: entry.account.id)
        }
        journal.append(transaction)
    }

    // MARK: - Balance queries

    /// Computes the current balance for a single account.
    /// - Throws: `LedgerError.accountNotFound` if the account is not in the chart.
    public func balance(for accountID: UUID) throws -> AccountBalance {
        let account = try chartOfAccounts.account(id: accountID)
        return computeBalance(for: account, in: journal.transactions)
    }

    /// Returns balances for every account in the chart.
    public func allBalances() -> [AccountBalance] {
        chartOfAccounts.all.map { account in
            computeBalance(for: account, in: journal.transactions)
        }
    }

    /// Computes a trial balance: all account balances grouped and validated.
    ///
    /// In a correctly maintained ledger the sum of all debit totals equals
    /// the sum of all credit totals.
    ///
    /// - Returns: A `TrialBalance` snapshot.
    public func trialBalance() -> TrialBalance {
        TrialBalance(balances: allBalances())
    }

    // MARK: - Transaction history

    /// All transactions that touch a given account, optionally filtered by date range.
    public func transactions(
        for accountID: UUID,
        from start: Date? = nil,
        to end: Date? = nil
    ) throws -> [Transaction] {
        _ = try chartOfAccounts.account(id: accountID)
        if let start, let end {
            return journal.transactions(for: accountID, from: start, to: end)
        }
        return journal.transactions(for: accountID)
    }

    // MARK: - Private helpers

    private func computeBalance(for account: Account, in transactions: [Transaction]) -> AccountBalance {
        let relevantEntries = transactions
            .flatMap(\.entries)
            .filter { $0.account.id == account.id }

        let zero = Money(.zero, account.currency)
        let debitTotal = relevantEntries
            .filter { $0.side == .debit }
            .map(\.amount)
            .reduce(zero) { Money($0.amount + $1.amount, account.currency) }

        let creditTotal = relevantEntries
            .filter { $0.side == .credit }
            .map(\.amount)
            .reduce(zero) { Money($0.amount + $1.amount, account.currency) }

        return AccountBalance(account: account, debitTotal: debitTotal, creditTotal: creditTotal)
    }
}

// MARK: - Trial Balance

/// A snapshot of all account balances used to verify the ledger is in balance.
public struct TrialBalance: Sendable, Codable, Hashable {
    public let balances: [AccountBalance]

    /// `true` if total debits equal total credits across all accounts.
    public var isBalanced: Bool {
        let currencies = Set(balances.map(\.account.currency))
        for currency in currencies {
            let inCurrency = balances.filter { $0.account.currency == currency }
            let totalDebits = inCurrency.reduce(Decimal.zero) { $0 + $1.debitTotal.amount }
            let totalCredits = inCurrency.reduce(Decimal.zero) { $0 + $1.creditTotal.amount }
            if totalDebits != totalCredits { return false }
        }
        return true
    }

    /// Total debit amounts per currency.
    public func totalDebits(currency: CurrencyCode) -> Money {
        let sum = balances
            .filter { $0.account.currency == currency }
            .reduce(Decimal.zero) { $0 + $1.debitTotal.amount }
        return Money(sum, currency)
    }

    /// Total credit amounts per currency.
    public func totalCredits(currency: CurrencyCode) -> Money {
        let sum = balances
            .filter { $0.account.currency == currency }
            .reduce(Decimal.zero) { $0 + $1.creditTotal.amount }
        return Money(sum, currency)
    }
}
