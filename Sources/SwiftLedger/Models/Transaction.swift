import Foundation

/// An immutable, balanced journal transaction.
///
/// A transaction is a dated financial event that affects two or more accounts.
/// The sum of all posting amounts must be zero for each commodity present —
/// this invariant is enforced at construction time.
///
/// Use `JournalParser` to build transactions from plain-text `.ledger` files,
/// which also resolves elided amounts before constructing `Transaction` objects.
public struct Transaction: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    /// The effective date of the transaction.
    public let date: JournalDate
    /// Optional auxiliary/effective date (ledger `=` syntax).
    public let auxDate: JournalDate?
    /// Transaction-level clearing status.
    public let status: ClearingStatus
    /// Optional transaction code (e.g. cheque number), stored in `(…)`.
    public let code: String?
    /// Human-readable description / payee.
    public let description: String
    /// The postings (must balance to zero per commodity).
    public let postings: [Posting]
    /// Inline comment on the transaction header line.
    public let comment: String?

    /// Creates a validated transaction.
    ///
    /// - Throws: `LedgerError.emptyTransaction` if fewer than two postings are provided.
    /// - Throws: `LedgerError.unbalancedTransaction` if postings do not sum to zero
    ///   for any commodity.
    public init(
        id: UUID = UUID(),
        date: JournalDate,
        auxDate: JournalDate? = nil,
        status: ClearingStatus = .unmarked,
        code: String? = nil,
        description: String,
        postings: [Posting],
        comment: String? = nil
    ) throws {
        guard postings.count >= 2 else { throw LedgerError.emptyTransaction }
        try Self.validateBalance(postings)
        self.id = id
        self.date = date
        self.auxDate = auxDate
        self.status = status
        self.code = code
        self.description = description
        self.postings = postings
        self.comment = comment
    }

    // MARK: - Private

    private static func validateBalance(_ postings: [Posting]) throws {
        var sums: [String: Decimal] = [:]
        for posting in postings {
            sums[posting.amount.commodity, default: .zero] += posting.amount.quantity
        }
        for (commodity, sum) in sums where sum != .zero {
            throw LedgerError.unbalancedTransaction(commodity: commodity, imbalance: sum)
        }
    }
}
