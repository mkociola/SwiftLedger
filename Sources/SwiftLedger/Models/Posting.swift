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
    /// A per-unit price multiplies. A total price is the whole cost already,
    /// and hledger reads it as the per-unit price `total / |quantity|`, so the
    /// cost is the total with the quantity's sign applied to it and the
    /// total's own sign kept: selling ten shares (`-10 AAPL @@ $1,500.00`)
    /// costs `-$1,500.00` even though the line writes the total unsigned, and
    /// a total written negative (`100 EUR @@ $-110.00`) costs `-$110.00`
    /// rather than the `$110.00` that taking the magnitude would make of it.
    /// A negative total is unusual but legal in both tools, and reading its
    /// sign away left an entry hledger balances unloadable here.
    public func cost(of quantity: Decimal) -> Amount {
        let priced = amount
        let value: Decimal =
            switch self {
            case .perUnit: quantity * priced.quantity
            case .total: quantity < 0 ? -priced.quantity : priced.quantity
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
///
/// A posting is real unless the journal wrapped its account name in `(…)` or
/// `[…]`, which ledger and hledger read as virtual-posting markers — see
/// `Kind`. The delimiters are not part of the name.
public struct Posting: Sendable, Codable, Hashable {
    /// Whether this posting takes part in its transaction's balance, and how
    /// the journal writes its account name.
    ///
    /// The raw values are the JSON spelling; a posting encoded before this
    /// existed decodes as `.real`.
    public enum Kind: String, Sendable, Codable, Hashable {
        /// An ordinary posting, written bare. Real postings must sum to zero
        /// per commodity.
        case real
        /// Written `(account)`: money moved outside the double-entry books,
        /// taking no part in any balance and never checked.
        case virtual
        /// Written `[account]`: exempt from balancing against the real
        /// postings, but the bracketed postings of one transaction must sum to
        /// zero per commodity among themselves.
        case balancedVirtual
    }

    /// Full account name (e.g. `"Expenses:Food:Groceries"`), always bare: a
    /// virtual posting's `(…)` / `[…]` delimiters are stripped by the parser
    /// and written back by the serializer, so every query matches one spelling.
    public let accountName: String
    /// Whether the posting is real, virtual, or balanced virtual.
    ///
    /// `Hashable`/`Equatable` are synthesized, so this takes part in
    /// `Posting ==`. That is deliberate: a real posting is not the same posting
    /// as a bracketed one, and callers that compare postings by content — an
    /// edit re-anchoring itself after a reparse, a conflict merge weighing two
    /// versions of a file — have to see the difference.
    public let kind: Kind
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

    /// How many digits the file wrote after the decimal mark for `amount`, or
    /// `nil` for a posting built in code.
    ///
    /// `Decimal` normalises its own scale on construction, so `1.00` and `1`
    /// are one value and nothing in the number itself remembers which of them
    /// the file wrote. This is the only record of it, and it is what sets the
    /// tolerance a transaction balances within: hledger reads a residual as
    /// zero when it is too small to show at the precision the entry writes
    /// that commodity in, so how the amount was typed decides whether the file
    /// loads. See `Transaction.balance(of:commodityFormats:)`.
    ///
    /// Nothing but the parser sets it. An amount the parser inferred rather
    /// than read, the fill of an elided posting, leaves it `nil`, since the
    /// file wrote no digits for it.
    public private(set) var amountScale: Int?

    /// The same for the amount written after this posting's `@` or `@@`.
    ///
    /// A price's own digits never tighten the tolerance of a commodity the
    /// entry writes a plain amount in (hledger measures the amounts, not the
    /// rates). They are all there is to measure for a commodity that appears
    /// in the entry only as a price, which is where this is read.
    public private(set) var priceScale: Int?

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

    /// The account name written the way a journal writes it for this kind of
    /// posting: bare for a real one, `(name)` for a virtual one, `[name]` for a
    /// balanced virtual one.
    ///
    /// This is the spelling `JournalSerializer` puts back on the line, and the
    /// one a register or an account picker should show, so that a reader can
    /// tell an envelope leg from an ordinary one at a glance.
    public var delimitedAccountName: String {
        kind.delimited(accountName)
    }

    public init(
        accountName: String,
        kind: Kind = .real,
        amount: Amount,
        price: PostingPrice? = nil,
        balanceAssertion: Amount? = nil,
        status: ClearingStatus? = nil,
        comment: String? = nil,
        trailingComments: [String] = [],
    ) {
        self.accountName = accountName
        self.kind = kind
        self.amount = amount
        self.price = price
        self.balanceAssertion = balanceAssertion
        self.status = status
        self.comment = comment
        self.trailingComments = trailingComments
    }

    // MARK: - Internal

    /// A copy of this posting tagged with the number of fraction digits its
    /// file wrote for the amount and for the price.
    ///
    /// Internal, and the only way the two scales are ever set: only the parser
    /// sees the text a number was written as, and a posting anything else
    /// built is going to be written by the serializer rather than read from a
    /// file. `Transaction.sourceText` is held for the same reason and in the
    /// same way.
    func taggedWithScales(amount amountScale: Int?, price priceScale: Int?) -> Posting {
        var copy = self
        copy.amountScale = amountScale
        copy.priceScale = priceScale
        return copy
    }

    /// The encoded shape of a posting. The written scales are deliberately
    /// absent: they describe how one file typed a number, not the movement the
    /// posting records, and a posting that has been through JSON is one built
    /// in code.
    private enum CodingKeys: String, CodingKey {
        case accountName, kind, amount, price, balanceAssertion, status, comment, trailingComments
    }

    /// Decodes a posting, treating a missing `kind`, `trailingComments`,
    /// `price` or `balanceAssertion` key as absent so that JSON written before
    /// those keys existed still decodes — a posting with no `kind` is real,
    /// which is what every posting written before virtual ones were modelled
    /// was.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountName = try container.decode(String.self, forKey: .accountName)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .real
        amount = try container.decode(Amount.self, forKey: .amount)
        price = try container.decodeIfPresent(PostingPrice.self, forKey: .price)
        balanceAssertion = try container.decodeIfPresent(Amount.self, forKey: .balanceAssertion)
        status = try container.decodeIfPresent(ClearingStatus.self, forKey: .status)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        trailingComments = try container.decodeIfPresent([String].self, forKey: .trailingComments) ?? []
    }

    // MARK: - Equality

    /// Two postings are equal when they record the same movement, however
    /// either one's number was typed.
    ///
    /// `amountScale` and `priceScale` are excluded for the reason
    /// `Transaction.sourceText` is: they are typography, and callers compare
    /// postings by content across a reparse. An edit sheet re-anchoring itself
    /// on the entry it is editing, and a conflict merge weighing two versions
    /// of a file, would both start missing matches the moment `$1.00` stopped
    /// equalling the `$1` a caller rebuilt.
    public static func == (lhs: Posting, rhs: Posting) -> Bool {
        lhs.accountName == rhs.accountName
            && lhs.kind == rhs.kind
            && lhs.amount == rhs.amount
            && lhs.price == rhs.price
            && lhs.balanceAssertion == rhs.balanceAssertion
            && lhs.status == rhs.status
            && lhs.comment == rhs.comment
            && lhs.trailingComments == rhs.trailingComments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(accountName)
        hasher.combine(kind)
        hasher.combine(amount)
        hasher.combine(price)
        hasher.combine(balanceAssertion)
        hasher.combine(status)
        hasher.combine(comment)
        hasher.combine(trailingComments)
    }
}

// MARK: - Delimiters

public extension Posting.Kind {
    /// `name` written the way a journal writes it for this kind.
    func delimited(_ name: String) -> String {
        switch self {
        case .real: name
        case .virtual: "(\(name))"
        case .balancedVirtual: "[\(name)]"
        }
    }
}

extension Posting.Kind {
    /// The bare name and the kind a written account token states: `(name)` is
    /// virtual, `[name]` balanced virtual, anything else real and taken
    /// verbatim.
    ///
    /// Both ends must match and there must be something between them, so an
    /// unmatched bracket (`[Reserve:capital`) is part of the name, as are
    /// parentheses in the middle of one (`Assets:Car (old)`) and an empty pair
    /// (`()`). Only the outermost pair is stripped: `((A))` is the virtual
    /// account named `(A)`. Space just inside the delimiters is padding rather
    /// than name, so `( Reserve:capital )` is the same account as
    /// `(Reserve:capital)` and is written back without the padding.
    ///
    /// The parser reads every posting line through this, on the token past the
    /// status marker and the two-space gap. `Transaction` refuses a real
    /// posting whose name this does not answer `.real` for, because such a
    /// name is written bare and would come back from the next parse virtual.
    static func split(_ token: String) -> (name: String, kind: Posting.Kind) {
        guard token.count >= 3,
              let open = token.first, let close = token.last,
              let kind = Posting.Kind(open: open, close: close) else { return (token, .real) }
        let inner = token.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return (token, .real) }
        return (inner, kind)
    }

    /// The kind a pair of delimiters states, or `nil` when they are not a
    /// matched virtual-posting pair.
    init?(open: Character, close: Character) {
        switch (open, close) {
        case ("(", ")"): self = .virtual
        case ("[", "]"): self = .balancedVirtual
        default: return nil
        }
    }
}
