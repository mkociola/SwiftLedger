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

    public init(
        accountName: String,
        amount: Amount,
        status: ClearingStatus? = nil,
        comment: String? = nil,
    ) {
        self.accountName = accountName
        self.amount = amount
        self.status = status
        self.comment = comment
    }
}
