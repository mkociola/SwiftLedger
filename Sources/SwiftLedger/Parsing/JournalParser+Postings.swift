// MARK: - Reading one posting line

import Foundation

extension JournalParser {
    struct RawPosting {
        var accountName: String
        var kind: Posting.Kind
        var amount: Amount?
        var price: PostingPrice?
        var balanceAssertion: Amount?
        var status: ClearingStatus?
        var comment: String?
        /// Full-line comments written below this posting, verbatim.
        var trailingComments: [String] = []
    }

    func parsePosting(
        _ line: String,
        lineNumber: Int,
        into style: inout JournalStyleCollector,
    ) throws -> RawPosting {
        var rest = line.trimmingCharacters(in: .whitespaces)

        // Optional status (* or !)
        var postingStatus: ClearingStatus?
        if rest.hasPrefix("* ") || rest.hasPrefix("! ") {
            postingStatus = rest.hasPrefix("*") ? .cleared : .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Account name ends at 2+ spaces, or at end of line. The token is kept
        // as the line writes it for the style observation below; the posting
        // stores the bare name. The comment is split off what follows the
        // name rather than off the whole line, because there the `;` needs no
        // two spaces in front of it, and the field the margin is measured
        // against is the one with the comment already gone.
        let (accountToken, field) = splitAccountAndAmount(rest)
        let (amountStr, comment) = splitPostingComment(field)
        let (accountName, kind) = Posting.Kind.split(accountToken)
        style.observeIndent(String(line.prefix { $0 == " " || $0 == "\t" }))
        if let amountStr, let start = Self.amountColumn(in: line, after: accountToken) {
            style.observeAmountField(start: start, end: start + amountStr.count)
        }

        // The amount may be trailed by a price and/or a balance assertion.
        // An empty part is dropped rather than parsed: a dangling `@` is not
        // an amount, and refusing to load the file over one would be the very
        // failure this splitting exists to remove.
        var amount: Amount?
        var price: PostingPrice?
        var balanceAssertion: Amount?
        if let rawAmount = amountStr {
            let field = splitAmountField(rawAmount)
            if !field.amount.isEmpty {
                let parsed = try parseShapedAmount(field.amount, lineNumber: lineNumber)
                style.observe(field.amount, shape: parsed.shape, as: parsed.amount)
                amount = parsed.amount
            }
            if let rawPrice = field.price, !rawPrice.isEmpty {
                let priced = try parseShapedAmount(rawPrice, lineNumber: lineNumber)
                style.observe(rawPrice, shape: priced.shape, as: priced.amount)
                price = field.priceIsTotal ? .total(priced.amount) : .perUnit(priced.amount)
            }
            if let rawAssertion = field.assertion, !rawAssertion.isEmpty {
                let asserted = try parseShapedAmount(rawAssertion, lineNumber: lineNumber)
                style.observe(rawAssertion, shape: asserted.shape, as: asserted.amount)
                balanceAssertion = asserted.amount
            }
        }

        return RawPosting(
            accountName: accountName,
            kind: kind,
            amount: amount,
            price: price,
            balanceAssertion: balanceAssertion,
            status: postingStatus,
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
    }
}
