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
            case .accountDirective(let d):
                lines.append("account \(d.name)")
            case .transaction(let t):
                lines.append(contentsOf: serializeTransaction(t))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Transaction serialisation

    private func serializeTransaction(_ t: Transaction) -> [String] {
        var lines: [String] = []

        // Header line
        var header = t.date.description
        if let aux = t.auxDate {
            header += "=\(aux.description)"
        }
        if t.status != .unmarked {
            header += " \(t.status.rawValue)"
        }
        if let code = t.code {
            header += " (\(code))"
        }
        header += " \(t.description)"
        if let c = t.comment {
            header += "  ; \(c)"
        }
        lines.append(header)

        // Posting lines
        for p in t.postings {
            lines.append(serializePosting(p))
        }

        return lines
    }

    private func serializePosting(_ p: Posting) -> String {
        var line = "    "

        if let s = p.status, s != .unmarked {
            line += "\(s.rawValue) "
        }

        line += p.accountName

        let amountStr = formatAmount(p.amount)
        // Right-align amount at column 52
        let accountFieldWidth = 52 - 4 - (p.status != nil && p.status != .unmarked ? 2 : 0)
        let padding = accountFieldWidth - p.accountName.count
        if padding >= 2 {
            line += String(repeating: " ", count: padding)
            line += amountStr
        } else {
            line += "  \(amountStr)"
        }

        if let c = p.comment {
            line += "  ; \(c)"
        }

        return line
    }

    private func formatAmount(_ a: Amount) -> String {
        let q = formatDecimal(abs(a.quantity))
        let sign = a.quantity < 0 ? "-" : ""
        if a.commodityIsPrefix {
            return "\(sign)\(a.commodity)\(q)"
        } else {
            return "\(sign)\(q) \(a.commodity)"
        }
    }
}
