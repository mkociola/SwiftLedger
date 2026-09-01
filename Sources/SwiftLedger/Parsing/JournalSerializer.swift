import Foundation

/// Serialises a `Journal` back to plain-text `.ledger` / `.journal` format.
///
/// Round-trip fidelity goals:
/// - A transaction that came from `JournalParser` and was not changed since is
///   written back from its own source lines, byte for byte. A journal file the
///   caller only read therefore survives a save untouched — no re-alignment, no
///   re-formatted amounts, and a diff that shows only what the user did.
/// - Preserves blank lines, comments, and account directives.
/// - Full-line comments inside a transaction are written back verbatim, in
///   place, from `Transaction.leadingComments` and `Posting.trailingComments`.
/// - Lines the parser does not model (`include`, `P`, `commodity`, `alias`,
///   `D`, `year`, indented sub-directives, …) are written back verbatim.
///
/// The rules below describe the formatting applied to a transaction the caller
/// built or changed — one with no source lines of its own:
/// - Elided postings (resolved during parsing) are written with explicit amounts.
/// - Amounts are formatted using the stored `commodityIsPrefix` flag, in the
///   decimal places, thousands separators and minus-sign placement the rest of
///   the journal uses for that commodity (`Journal.commodityFormats`). A
///   `Decimal` has forgotten all three by the time it gets here, so without
///   that an edit to a payee would also restyle that entry's `$-1,234.50` to
///   `-$1234.5`.
/// - A posting's price and balance assertion are re-emitted after its amount,
///   in canonical `AMOUNT @ PRICE = ASSERTION` order.
/// - Postings are indented the way the rest of the journal indents its own
///   (`Journal.postingIndent`), falling back to 4 spaces.
/// - Amount fields are lined up the way the rest of the journal lines its own
///   up (`Journal.amountAlignment`) — beginning at one column, or ending at
///   one — falling back to beginning at column 52, the ledger-cli default, for
///   a journal that shows none.
public struct JournalSerializer {
    public init() {}

    // MARK: - Public API

    /// Serialises the journal to a string.
    public func serialize(_ journal: Journal) -> String {
        var lines: [String] = []
        for item in journal.items {
            switch item {
            case .blank:
                lines.append("")
            case let .comment(text):
                lines.append(isCommentLine(text) ? text : "; \(text)")
            case let .directive(raw):
                lines.append(raw)
            case let .accountDirective(directive):
                var line = "account \(directive.name)"
                if let comment = directive.comment {
                    line += "  ; \(comment)"
                }
                lines.append(line)
            case let .transaction(transaction):
                lines.append(contentsOf: serializeTransaction(
                    transaction,
                    formats: journal.commodityFormats,
                    alignment: journal.amountAlignment ?? Self.defaultAlignment,
                    indent: journal.postingIndent ?? Self.defaultIndent,
                ))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Comments

    /// Whether `text` already reads as a full-line comment and can be written
    /// back untouched.
    ///
    /// Text that does not — a programmatically supplied `.comment("reviewed")`,
    /// say — is given a `; ` marker, so serialising never emits a line the
    /// parser would read back as something other than a comment.
    private func isCommentLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*")
    }

    /// Renders one full-line comment belonging to a transaction body.
    ///
    /// A line that already reads as an in-transaction comment — indented, and
    /// marked with `;` or `#` — is written back untouched. Anything else is
    /// indented and given a `; ` marker, so serialising never emits a line the
    /// parser would read back as a posting, a status-marked line, or a
    /// top-level comment outside the transaction.
    private func transactionCommentLine(_ text: String) -> String {
        let isIndented = text.first == " " || text.first == "\t"
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isMarked = trimmed.hasPrefix(";") || trimmed.hasPrefix("#")
        if isIndented, isMarked {
            return text
        }
        return "    " + (isMarked ? trimmed : "; \(trimmed)")
    }

    // MARK: - Transaction serialisation

    /// How amounts are lined up when the journal shows no margin of its own:
    /// beginning at column 52, ledger-cli's default and what SwiftLedger has
    /// always written.
    static let defaultAlignment = AmountAlignment.start(column: 52)

    /// How postings are indented when the journal shows no indent of its own.
    static let defaultIndent = "    "

    private func serializeTransaction(
        _ transaction: Transaction,
        formats: [String: CommodityFormat],
        alignment: AmountAlignment,
        indent: String,
    ) -> [String] {
        // Parsed and untouched: hand back the user's own lines. Formatting them
        // would rewrite the whole file on any edit, which is exactly what a
        // plain-text journal kept in version control cannot afford.
        if let source = transaction.sourceText {
            return source.components(separatedBy: "\n")
        }

        var lines: [String] = []

        // Header line
        var header = transaction.date.description
        if let aux = transaction.auxDate {
            header += "=\(aux.description)"
        }
        if transaction.status != .unmarked {
            header += " \(transaction.status.rawValue)"
        }
        if let code = transaction.code {
            header += " (\(code))"
        }
        header += " \(transaction.description)"
        if let comment = transaction.comment {
            header += "  ; \(comment)"
        }
        lines.append(header)

        // Comment lines written before the first posting
        for comment in transaction.leadingComments {
            lines.append(transactionCommentLine(comment))
        }

        // Posting lines, each followed by the comment lines written below it
        for posting in transaction.postings {
            lines.append(serializePosting(posting, formats: formats, alignment: alignment, indent: indent))
            for comment in posting.trailingComments {
                lines.append(transactionCommentLine(comment))
            }
        }

        return lines
    }

    private func serializePosting(
        _ posting: Posting,
        formats: [String: CommodityFormat],
        alignment: AmountAlignment,
        indent: String,
    ) -> String {
        var line = indent

        if let postingStatus = posting.status, postingStatus != .unmarked {
            line += "\(postingStatus.rawValue) "
        }

        line += posting.accountName

        let amountStr = formatPostingAmount(posting, formats: formats)
        // Pad to the journal's own margin — two spaces at minimum, since one
        // is not enough to separate an account name from an amount.
        let padding: Int = switch alignment {
        case let .start(column): column - line.count
        case let .end(column): column - line.count - amountStr.count
        }
        line += String(repeating: " ", count: max(2, padding))
        line += amountStr

        if let comment = posting.comment {
            line += "  ; \(comment)"
        }

        return line
    }

    /// The whole amount field of a posting: the amount, then whatever price
    /// and balance assertion it carries, in the order ledger writes them —
    /// `AMOUNT @ PRICE = ASSERTION`, canonically spaced.
    private func formatPostingAmount(_ posting: Posting, formats: [String: CommodityFormat]) -> String {
        var field = formatAmount(posting.amount, formats: formats)
        switch posting.price {
        case nil: break
        case let .perUnit(price): field += " @ \(formatAmount(price, formats: formats))"
        case let .total(price): field += " @@ \(formatAmount(price, formats: formats))"
        }
        if let assertion = posting.balanceAssertion {
            field += " = \(formatAmount(assertion, formats: formats))"
        }
        return field
    }

    /// Writes one amount in the journal's own style for its commodity, falling
    /// back to `CommodityFormat.default(for:)` for a commodity the file has no
    /// example of — a journal built in code, or the first `$` amount in a file
    /// that has none yet.
    ///
    /// The style sets a minimum number of decimal places, never a maximum, so
    /// an amount carrying more digits than the house style keeps all of them.
    /// Rounding here would change what the journal says and could leave a
    /// transaction that no longer balances.
    private func formatAmount(_ amount: Amount, formats: [String: CommodityFormat]) -> String {
        let format = formats[amount.commodity] ?? .default(for: amount.commodity)
        let absValue = format.render(abs(amount.quantity))
        let sign = amount.quantity < 0 ? "-" : ""
        guard amount.commodityIsPrefix else {
            return "\(sign)\(absValue) \(amount.commodity)"
        }
        return format.signPrecedesCommodity
            ? "\(sign)\(amount.commodity)\(absValue)"
            : "\(amount.commodity)\(sign)\(absValue)"
    }
}
