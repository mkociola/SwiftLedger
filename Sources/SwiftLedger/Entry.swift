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

    public init(account: Account, amount: Money, side: EntrySide) {
        self.account = account
        self.amount = amount
        self.side = side
    }
}

// MARK: - Convenience constructors

extension Entry {
    /// Creates a debit entry.
    public static func debit(account: Account, amount: Money) -> Entry {
        Entry(account: account, amount: amount, side: .debit)
    }

    /// Creates a credit entry.
    public static func credit(account: Account, amount: Money) -> Entry {
        Entry(account: account, amount: amount, side: .credit)
    }
}
