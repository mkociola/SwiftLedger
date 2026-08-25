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
    /// Full-line comments written between the header line and the first
    /// posting.
    ///
    /// Each element is the source line **verbatim**, indentation and `;`/`#`
    /// marker included, so the original layout survives a serialisation
    /// round-trip. Comments appearing lower down are attached to the posting
    /// above them as `Posting.trailingComments`.
    public let leadingComments: [String]

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
        comment: String? = nil,
        leadingComments: [String] = [],
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
        self.leadingComments = leadingComments
    }

    /// Decodes a transaction, treating a missing `leadingComments` key as no
    /// comments so that JSON written before the key existed still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(JournalDate.self, forKey: .date)
        auxDate = try container.decodeIfPresent(JournalDate.self, forKey: .auxDate)
        status = try container.decode(ClearingStatus.self, forKey: .status)
        code = try container.decodeIfPresent(String.self, forKey: .code)
        description = try container.decode(String.self, forKey: .description)
        postings = try container.decode([Posting].self, forKey: .postings)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        leadingComments = try container.decodeIfPresent([String].self, forKey: .leadingComments) ?? []
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
