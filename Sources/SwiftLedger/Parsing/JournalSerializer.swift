import Foundation

/// Serialises a `Journal` back to plain-text `.ledger` / `.journal` format.
///
/// Round-trip fidelity goals:
/// - Preserves blank lines, comments, and account directives.
/// - Full-line comments inside a transaction are written back verbatim, in
///   place, from `Transaction.leadingComments` and `Posting.trailingComments`.
/// - Lines the parser does not model (`include`, `P`, `commodity`, `alias`,
///   `D`, `year`, indented sub-directives, …) are written back verbatim.
/// - Elided postings (resolved during parsing) are written with explicit amounts.
/// - Amounts are formatted using the stored `commodityIsPrefix` flag.
/// - Postings are indented with 4 spaces.
/// - Amounts are right-aligned at column 52 (same as ledger-cli default).
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
                lines.append(contentsOf: serializeTransaction(transaction))
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

    private func serializeTransaction(_ transaction: Transaction) -> [String] {
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
            lines.append(serializePosting(posting))
            for comment in posting.trailingComments {
                lines.append(transactionCommentLine(comment))
            }
        }

        return lines
    }

    private func serializePosting(_ posting: Posting) -> String {
        var line = "    "

        if let postingStatus = posting.status, postingStatus != .unmarked {
            line += "\(postingStatus.rawValue) "
        }

        line += posting.accountName

        let amountStr = formatAmount(posting.amount)
        // Right-align amount at column 52
        let accountFieldWidth = 52 - 4 - (posting.status != nil && posting.status != .unmarked ? 2 : 0)
        let padding = accountFieldWidth - posting.accountName.count
        if padding >= 2 {
            line += String(repeating: " ", count: padding)
            line += amountStr
        } else {
            line += "  \(amountStr)"
        }

        if let comment = posting.comment {
            line += "  ; \(comment)"
        }

        return line
    }

    private func formatAmount(_ amount: Amount) -> String {
        let absValue = abs(amount.quantity).description
        let sign = amount.quantity < 0 ? "-" : ""
        if amount.commodityIsPrefix {
            return "\(sign)\(amount.commodity)\(absValue)"
        } else {
            return "\(sign)\(absValue) \(amount.commodity)"
        }
    }
}
