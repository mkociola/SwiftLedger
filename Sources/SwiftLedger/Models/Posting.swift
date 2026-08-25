/// A single line in a journal transaction: a movement of an amount to/from
/// one account.
///
/// Positive `amount.quantity` = inflow to the account (debit in traditional terms).
/// Negative `amount.quantity` = outflow from the account (credit).
public struct Posting: Sendable, Codable, Hashable {
    /// Full account name (e.g. `"Expenses:Food:Groceries"`).
    public let accountName: String
    /// The signed amount. Always present in the stored model; elision is
    /// resolved during parsing before `Posting` objects are created.
    public let amount: Amount
    /// Optional posting-level clearing status (overrides the transaction status).
    public let status: ClearingStatus?
    /// Inline comment text (the part after `; ` on the posting line).
    public let comment: String?
    /// Full-line comments written underneath this posting, before the next
    /// posting or the end of the transaction.
    ///
    /// Each element is the source line **verbatim**, indentation and `;`/`#`
    /// marker included, so the original layout survives a serialisation
    /// round-trip. These lines are commentary only: they are not postings and
    /// take no part in balancing.
    public let trailingComments: [String]

    public init(
        accountName: String,
        amount: Amount,
        status: ClearingStatus? = nil,
        comment: String? = nil,
        trailingComments: [String] = [],
    ) {
        self.accountName = accountName
        self.amount = amount
        self.status = status
        self.comment = comment
        self.trailingComments = trailingComments
    }

    /// Decodes a posting, treating a missing `trailingComments` key as no
    /// comments so that JSON written before the key existed still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountName = try container.decode(String.self, forKey: .accountName)
        amount = try container.decode(Amount.self, forKey: .amount)
        status = try container.decodeIfPresent(ClearingStatus.self, forKey: .status)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        trailingComments = try container.decodeIfPresent([String].self, forKey: .trailingComments) ?? []
    }
}
