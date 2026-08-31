import Foundation

/// An immutable, balanced journal transaction.
///
/// A transaction is a dated financial event that affects two or more accounts.
/// The sum of all posting amounts must be zero for each commodity present —
/// this invariant is enforced at construction time.
///
/// A posting that carries a price balances at that price rather than at face
/// value (`Posting.balancingAmount`), which is what lets a two-commodity trade
/// net to zero: `10 AAPL @ $150.00` against `$-1,500.00` balances, because the
/// share leg counts as the $1,500 it cost. Balance assertions take no part in
/// this — they are preserved, never checked.
///
/// Use `JournalParser` to build transactions from plain-text `.ledger` files,
/// which also resolves elided amounts before constructing `Transaction` objects.
/// A transaction that comes back from the parser also carries the lines it was
/// read from, in `sourceText`, so that leaving it alone leaves the file alone.
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

    /// The lines this transaction was parsed from, **verbatim**, or `nil` when
    /// it was not parsed from a file.
    ///
    /// A journal is a text file people keep in version control and read diffs
    /// of. Formatting every transaction on every save turns a one-line edit
    /// into a whole-file rewrite, so a transaction that came out of the parser
    /// and was not touched is written back exactly as it came in — trailing
    /// zeros, thousands separators, hand-aligned columns, elided amounts and
    /// all. This is the same guarantee `JournalItem.directive` already gives
    /// unmodelled lines, extended to the lines SwiftLedger does understand.
    ///
    /// Holding source text is what makes "untouched" decidable. Nothing but
    /// the parser can set it, every other way of making a `Transaction` leaves
    /// it `nil`, and a transaction rebuilt through `init` to change a posting
    /// therefore loses it and is formatted afresh. It cannot go stale.
    ///
    /// It is not part of the value: two transactions recording the same event
    /// are equal whatever text either was read from, and it is not encoded, so
    /// a transaction that has been through JSON is formatted like any other
    /// transaction built in code.
    public private(set) var sourceText: String?

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

    /// The encoded shape of a transaction. `sourceText` is deliberately absent:
    /// it describes one file's layout, not the event, and a decoded transaction
    /// is meant to be formatted rather than to replay lines from elsewhere.
    private enum CodingKeys: String, CodingKey {
        case id, date, auxDate, status, code, description, postings, comment, leadingComments
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

    // MARK: - Equality

    /// Two transactions are equal when they record the same event — `id`
    /// included, so a copy equals its original and a re-entry does not.
    ///
    /// `sourceText` is excluded on purpose. Comparing it would make a parsed
    /// transaction unequal to the identical one a caller reconstructs, and
    /// `Journal.remove(_:)` finds items by value: removing a transaction would
    /// start depending on whether the caller happened to hold the parsed copy.
    public static func == (lhs: Transaction, rhs: Transaction) -> Bool {
        lhs.id == rhs.id
            && lhs.date == rhs.date
            && lhs.auxDate == rhs.auxDate
            && lhs.status == rhs.status
            && lhs.code == rhs.code
            && lhs.description == rhs.description
            && lhs.postings == rhs.postings
            && lhs.comment == rhs.comment
            && lhs.leadingComments == rhs.leadingComments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(date)
        hasher.combine(description)
        hasher.combine(postings)
    }

    // MARK: - Internal

    /// A copy of this transaction tagged with the source lines it was parsed
    /// from.
    ///
    /// Internal, and the only way `sourceText` is ever set: only the parser
    /// knows which lines produced a transaction, and only a transaction that
    /// nothing has changed since may claim them.
    func taggedWithSource(_ text: String) -> Transaction {
        var copy = self
        copy.sourceText = text
        return copy
    }

    // MARK: - Private

    private static func validateBalance(_ postings: [Posting]) throws {
        var sums: [String: Decimal] = [:]
        for posting in postings {
            let balancing = posting.balancingAmount
            sums[balancing.commodity, default: .zero] += balancing.quantity
        }
        for (commodity, sum) in sums where sum != .zero {
            throw LedgerError.unbalancedTransaction(commodity: commodity, imbalance: sum)
        }
    }
}
