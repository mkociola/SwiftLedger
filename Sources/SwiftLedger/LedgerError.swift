import Foundation

/// Errors thrown by the SwiftLedger library.
public enum LedgerError: Error, Sendable {
    /// A transaction's debit and credit totals do not balance.
    case unbalanced(debitTotal: Money, creditTotal: Money)
    /// A transaction was created with no entries.
    case emptyTransaction
    /// Two amounts in the same operation use different currencies.
    case currencyMismatch(Money, Money)
    /// An account with the same ID already exists in the chart of accounts.
    case duplicateAccount(Account)
    /// No account matching the given identifier was found.
    case accountNotFound(UUID)
    /// An entry amount is zero or negative; amounts must be strictly positive.
    case invalidAmount(Money)
    /// An account cannot be removed because it has posted transactions.
    case accountHasTransactions(Account)
    /// No transaction matching the given identifier was found in the journal.
    case transactionNotFound(UUID)
}

extension LedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unbalanced(let d, let c):
            "Transaction is unbalanced: debits \(d) ≠ credits \(c)"
        case .emptyTransaction:
            "A transaction must contain at least one entry"
        case .currencyMismatch(let a, let b):
            "Currency mismatch between \(a.currency) and \(b.currency)"
        case .duplicateAccount(let a):
            "Account '\(a.name)' (\(a.id)) already exists"
        case .accountNotFound(let id):
            "No account found with id \(id)"
        case .invalidAmount(let m):
            "Entry amount must be positive, got \(m)"
        case .accountHasTransactions(let a):
            "Cannot remove account '\(a.name)': it has posted transactions"
        case .transactionNotFound(let id):
            "No transaction found with id \(id)"
        }
    }
}
