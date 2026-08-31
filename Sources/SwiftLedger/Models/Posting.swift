import Foundation

/// The price a posting's amount was exchanged at, as written after `@` or `@@`
/// on the posting line.
///
/// A price is what lets a transaction in two commodities balance. The posting
/// `Assets:Brokerage  10 AAPL @ $150.00` moves ten shares, but what it *costs*
/// is $1,500, and it is the $1,500 that has to net against the cash leg — see
/// `Posting.balancingAmount`.
///
/// The two spellings mean the same thing and are kept apart anyway, because
/// which one the author wrote is part of the file: normalising `@@` to `@`
/// would rewrite a line the user did not ask to have rewritten.
///
/// SwiftLedger records the price on the posting that carries it and writes it
/// back. It keeps no price history — a `P` directive is preserved verbatim as
/// an unmodelled `.directive` line and is never consulted — so nothing here
/// values a holding at any date other than the one it was traded on.
public enum PostingPrice: Sendable, Codable, Hashable {
    /// A per-unit price, written `@`: `10 AAPL @ $150.00` costs $1,500.
    case perUnit(Amount)
    /// A price for the posting as a whole, written `@@`:
    /// `10 AAPL @@ $1,500.00` costs the same $1,500, stated outright.
    case total(Amount)

    /// The amount written after the `@` / `@@`, whichever spelling was used.
    public var amount: Amount {
        switch self {
        case let .perUnit(amount), let .total(amount): amount
        }
    }

    /// What `quantity` units cost at this price, in the price's commodity.
    ///
    /// A per-unit price multiplies. A total price is the whole cost already, so
    /// it only takes its sign from `quantity`: selling ten shares
    /// (`-10 AAPL @@ $1,500.00`) costs `-$1,500.00`, not `$1,500.00`, even
    /// though the line writes the total unsigned.
    public func cost(of quantity: Decimal) -> Amount {
        let priced = amount
        let value: Decimal =
            switch self {
            case .perUnit: quantity * priced.quantity
            case .total: quantity < 0 ? -abs(priced.quantity) : abs(priced.quantity)
            }
        return Amount(
            quantity: value,
            commodity: priced.commodity,
            commodityIsPrefix: priced.commodityIsPrefix,
        )
    }
}

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
    /// The price `amount` was exchanged at, from a trailing `@` or `@@`, or
    /// `nil` for the ordinary single-commodity posting.
    ///
    /// A price changes what the posting contributes to its transaction's
    /// balance — see `balancingAmount`. It does not change `amount`, which
    /// stays the quantity of the commodity that actually moved.
    public let price: PostingPrice?
    /// A balance assertion from a trailing `= <amount>`: what the journal
    /// claims the account's balance is *after* this posting.
    ///
    /// Parsed, carried, and written back unchanged — and **never checked**.
    /// Verifying an assertion means replaying every earlier posting for the
    /// account and telling the user which ones disagree; that is a feature of
    /// its own, with a report to go with it, and it does not exist yet. Until
    /// it does, an assertion is data SwiftLedger preserves, not a promise it
    /// enforces: no initialiser throws because an assertion is wrong, and no
    /// query consults one.
    public let balanceAssertion: Amount?
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

    /// What this posting contributes when its transaction is balanced.
    ///
    /// Without a price that is just `amount` — the common case, and the only
    /// case before prices were modelled. With one it is the cost the price
    /// states, in the price's commodity, which is how ledger balances a trade
    /// that spans two commodities: `10 AAPL @ $150.00` contributes `$1,500.00`
    /// and nets to zero against a plain `$-1,500.00` cash leg, even though no
    /// two postings share a commodity.
    public var balancingAmount: Amount {
        price?.cost(of: amount.quantity) ?? amount
    }

    public init(
        accountName: String,
        amount: Amount,
        price: PostingPrice? = nil,
        balanceAssertion: Amount? = nil,
        status: ClearingStatus? = nil,
        comment: String? = nil,
        trailingComments: [String] = [],
    ) {
        self.accountName = accountName
        self.amount = amount
        self.price = price
        self.balanceAssertion = balanceAssertion
        self.status = status
        self.comment = comment
        self.trailingComments = trailingComments
    }

    /// Decodes a posting, treating a missing `trailingComments`, `price` or
    /// `balanceAssertion` key as absent so that JSON written before those keys
    /// existed still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountName = try container.decode(String.self, forKey: .accountName)
        amount = try container.decode(Amount.self, forKey: .amount)
        price = try container.decodeIfPresent(PostingPrice.self, forKey: .price)
        balanceAssertion = try container.decodeIfPresent(Amount.self, forKey: .balanceAssertion)
        status = try container.decodeIfPresent(ClearingStatus.self, forKey: .status)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        trailingComments = try container.decodeIfPresent([String].self, forKey: .trailingComments) ?? []
    }
}
