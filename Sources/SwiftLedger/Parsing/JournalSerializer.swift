import Foundation

/// Serialises a `Journal` back to plain-text `.ledger` / `.journal` format.
///
/// Round-trip fidelity goals:
/// - Preserves blank lines, comments, and account directives.
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
            case .comment(let text):
                lines.append(text.hasPrefix(";") || text.hasPrefix("#") ? text : "; \(text)")
            case .accountDirective(let directive):
                lines.append("account \(directive.name)")
            case .transaction(let transaction):
                lines.append(contentsOf: serializeTransaction(transaction))
            }
        }
        return lines.joined(separator: "\n")
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

        // Posting lines
        for posting in transaction.postings {
            lines.append(serializePosting(posting))
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
