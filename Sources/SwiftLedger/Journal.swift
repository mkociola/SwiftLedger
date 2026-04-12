import Foundation

/// An append-only, ordered log of all posted transactions.
public struct Journal: Sendable, Codable, Hashable {
    private(set) var transactions: [Transaction] = []

    public init() {}

    // MARK: - Appending

    mutating func append(_ transaction: Transaction) {
        transactions.append(transaction)
    }

    // MARK: - Queries

    /// All transactions involving a specific account.
    public func transactions(for accountID: UUID) -> [Transaction] {
        transactions.filter { tx in
            tx.entries.contains { $0.account.id == accountID }
        }
    }

    /// Transactions within a date range (inclusive on both ends).
    public func transactions(from start: Date, to end: Date) -> [Transaction] {
        transactions.filter { $0.date >= start && $0.date <= end }
    }

    /// Transactions for an account within a date range.
    public func transactions(for accountID: UUID, from start: Date, to end: Date) -> [Transaction] {
        transactions(for: accountID).filter { $0.date >= start && $0.date <= end }
    }

    public var count: Int { transactions.count }
    public var isEmpty: Bool { transactions.isEmpty }
}
