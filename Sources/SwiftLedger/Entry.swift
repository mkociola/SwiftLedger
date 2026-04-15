import Foundation

/// Which side of the ledger an entry is recorded on.
public enum EntrySide: String, Sendable, Codable, Hashable {
    case debit
    case credit

    /// The opposite side.
    public var opposite: EntrySide {
        self == .debit ? .credit : .debit
    }
}

/// A single line in a journal transaction: a debit or credit to one account.
public struct Entry: Sendable, Codable, Hashable {
    /// The account being debited or credited.
    public let account: Account
    /// The amount (always positive).
    public let amount: Money
    /// The side of the ledger this entry is recorded on.
    public let side: EntrySide

    /// Creates a validated entry.
    ///
    /// - Throws: `LedgerError.invalidAmount` if `amount` is zero or negative.
    /// - Throws: `LedgerError.currencyMismatch` if `amount.currency` differs from `account.currency`.
    public init(account: Account, amount: Money, side: EntrySide) throws {
        guard amount.amount > .zero else {
            throw LedgerError.invalidAmount(amount)
        }
        guard amount.currency == account.currency else {
            throw LedgerError.currencyMismatch(amount, Money(.zero, account.currency))
        }
        self.account = account
        self.amount = amount
        self.side = side
    }
}

// MARK: - Convenience constructors

extension Entry {
    /// Creates a debit entry.
    public static func debit(account: Account, amount: Money) throws -> Entry {
        try Entry(account: account, amount: amount, side: .debit)
    }

    /// Creates a credit entry.
    public static func credit(account: Account, amount: Money) throws -> Entry {
        try Entry(account: account, amount: amount, side: .credit)
    }
}
