import Foundation

/// An immutable, balanced double-entry journal transaction.
///
/// A `Transaction` is validated at construction time: the sum of all debit
/// entries must equal the sum of all credit entries. If they don't, the
/// initializer throws `LedgerError.unbalanced`.
public struct Transaction: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    /// The date the transaction occurred.
    public let date: Date
    /// A short human-readable description (e.g. "Invoice #42 payment").
    public let memo: String
    /// One or more journal entries. Always balanced.
    public let entries: [Entry]

    /// Creates a validated transaction.
    ///
    /// - Throws: `LedgerError.emptyTransaction` if `entries` is empty.
    /// - Throws: `LedgerError.unbalanced` if debit total ≠ credit total.
    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        memo: String,
        entries: [Entry]
    ) throws {
        guard !entries.isEmpty else { throw LedgerError.emptyTransaction }

        let debits = entries.filter { $0.side == .debit }.map(\.amount)
        let credits = entries.filter { $0.side == .credit }.map(\.amount)

        // All entries in a transaction must share the same currency.
        let allAmounts = entries.map(\.amount)
        guard let currency = allAmounts.first?.currency,
              allAmounts.allSatisfy({ $0.currency == currency }) else {
            let first = allAmounts[0]
            let mismatch = allAmounts.first(where: { $0.currency != first.currency })!
            throw LedgerError.currencyMismatch(first, mismatch)
        }

        let zero = Money(.zero, currency)
        let debitTotal = try debits.reduce(zero) { try $0 + $1 }
        let creditTotal = try credits.reduce(zero) { try $0 + $1 }

        guard debitTotal == creditTotal else {
            throw LedgerError.unbalanced(debitTotal: debitTotal, creditTotal: creditTotal)
        }

        self.id = id
        self.date = date
        self.memo = memo
        self.entries = entries
    }

    /// Returns a new transaction that exactly reverses this one.
    ///
    /// Each entry's side is flipped (debit ↔ credit) and the memo is prefixed
    /// with "Reversal of: " unless a custom memo is supplied.
    ///
    /// - Parameters:
    ///   - memo: Override memo; defaults to `"Reversal of: <original memo>"`.
    ///   - date: Date for the reversing transaction; defaults to today.
    public func reversed(memo: String? = nil, date: Date = Date()) throws -> Transaction {
        let reversedMemo = memo ?? "Reversal of: \(self.memo)"
        let reversedEntries = try entries.map { entry in
            try Entry(account: entry.account, amount: entry.amount, side: entry.side.opposite)
        }
        return try Transaction(date: date, memo: reversedMemo, entries: reversedEntries)
    }
}
