// MARK: - Resolving elided posting amounts

import Foundation

extension JournalParser {
    /// Fills in the amount of the postings that elided one.
    ///
    /// Elision is resolved per balancing group, the way hledger infers one: at
    /// most one real posting may elide its amount and it takes what the other
    /// real postings leave over, and likewise at most one bracketed posting
    /// among the bracketed ones. The two groups never see each other, so an
    /// elided cash leg is not quietly paid for by an envelope.
    ///
    /// What the elided posting leaves over is a remainder per commodity, not a
    /// single amount: the standard opening-balances entry writes a dollar leg
    /// and a pound leg and lets one `equity:opening balances` line absorb both.
    /// Since `Posting` carries one amount, such a line expands here into one
    /// posting per commodity with something left to absorb (or a zero in each
    /// commodity when none has, see `remainders(of:in:)`), sorted by
    /// commodity symbol, sitting where the elided line was. That is what
    /// ledger and hledger infer, and it is the order hledger prints the entry
    /// back in.
    ///
    /// A parenthesised posting takes part in no balance, so there is nothing to
    /// infer its amount from and any number of them may elide one: each reads
    /// as zero, exactly as if the user had written it, which is also how an
    /// elision with nothing to balance against has always been read here.
    /// hledger is the tool followed on this point; ledger-cli would hand a lone
    /// null-amount posting the real remainder instead.
    ///
    /// A transaction with no postings has nothing to resolve and comes back
    /// empty.
    ///
    /// Returns, beside the postings and index for index with them, the digits
    /// each one's numbers were written with.
    func resolveElisions(
        _ rawPostings: [RawPosting],
    ) throws -> (postings: [Posting], written: [WrittenDigits]) {
        var fills: [Posting.Kind: [Amount]] = [:]
        for kind in [Posting.Kind.real, .balancedVirtual] {
            let group = rawPostings.filter { $0.kind == kind }
            let elided = group.count(where: { $0.amount == nil })
            guard elided <= 1 else { throw LedgerError.multipleElidedPostings }
            if elided == 1 { fills[kind] = try remainders(of: group, in: rawPostings) }
        }

        // An amount the parser inferred was written by nobody, so it brings
        // no digits of its own and is measured at the digits it needs.
        let resolved = try rawPostings.flatMap { raw -> [(Posting, WrittenDigits)] in
            if let amount = raw.amount { return [(Self.posting(from: raw, amount: amount), raw.written)] }
            if raw.kind == .virtual {
                return try [(Self.posting(from: raw, amount: zeroAmount(matching: rawPostings)), WrittenDigits())]
            }
            guard let fill = fills[raw.kind], !fill.isEmpty else {
                throw LedgerError.cannotResolveElision
            }
            return Self.postings(from: raw, amounts: fill).map { ($0, WrittenDigits()) }
        }
        return (resolved.map(\.0), resolved.map(\.1))
    }

    /// What the one posting of a group that elided its amount takes: minus the
    /// sum of what the rest of its own group wrote, one amount per commodity
    /// that does not already net to zero, sorted by symbol. The sort compares
    /// Unicode code points, as hledger does, rather than following a locale,
    /// so `EUR` comes before `eur` and both before `£` and `€`; the order the
    /// entry wrote them in plays no part. A
    /// priced posting contributes what it cost, not what it moved, so that a
    /// share purchase can balance an elided cash leg. A group in which nobody
    /// wrote an amount leaves zero to absorb, in the first commodity the entry
    /// writes (see `zeroAmount(matching:)`, which is where file order decides).
    ///
    /// A group whose written amounts already balance in every commodity leaves
    /// a zero in each of them rather than nothing, still sorted by symbol, so
    /// that the line the user wrote is still a posting and a rebuilt entry
    /// writes the `$0` and `0 EUR` lines `hledger print -x` writes. Only when
    /// some commodity leaves something over are the ones that net out
    /// dropped, which hledger does too.
    func remainders(of group: [RawPosting], in transaction: [RawPosting]) throws -> [Amount] {
        let written = group.compactMap { raw in
            raw.amount.map { raw.price?.cost(of: $0.quantity) ?? $0 }
        }
        guard !written.isEmpty else { return try [zeroAmount(matching: transaction)] }

        var sums: [String: (quantity: Decimal, isPrefix: Bool)] = [:]
        for amount in written {
            sums[amount.commodity, default: (.zero, amount.commodityIsPrefix)].quantity += amount.quantity
        }

        let remainders = sums
            .sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            .map { Amount(quantity: -$0.value.quantity, commodity: $0.key, commodityIsPrefix: $0.value.isPrefix) }
        let leftOver = remainders.filter { $0.quantity != .zero }
        return leftOver.isEmpty ? remainders : leftOver
    }

    /// Zero in the first commodity the entry writes, **in file order**: the
    /// amount of the first posting that wrote one, whichever group it belongs
    /// to, and the amount it moved rather than what a price on it says that
    /// cost.
    ///
    /// An entry of `$` amounts should not sprout a `USD` one because a
    /// parenthesised leg left its amount off — the balance would read `0 USD`
    /// and a rebuild would write `0 USD` into a dollar journal. In an entry
    /// written in one commodity that is simply the entry's commodity. In one
    /// written in two it is a document-order answer and nothing better is
    /// available: a posting in no balancing group has no commodity of its own,
    /// so moving the postings around can move which commodity its zero is in.
    /// Only an entry in which nobody wrote an amount at all has nothing to
    /// take a commodity from, and that falls back to `parseAmount`, so a
    /// written `0` and an elided one still produce the very same amount.
    func zeroAmount(matching rawPostings: [RawPosting]) throws -> Amount {
        guard let written = rawPostings.compactMap(\.amount).first else {
            return try parseAmount("0", lineNumber: 0)
        }
        return Amount(
            quantity: .zero, commodity: written.commodity, commodityIsPrefix: written.commodityIsPrefix,
        )
    }

    static func posting(from raw: RawPosting, amount: Amount) -> Posting {
        Posting(
            accountName: raw.accountName,
            kind: raw.kind,
            amount: amount,
            price: raw.price,
            balanceAssertion: raw.balanceAssertion,
            balanceAssertionOperator: raw.balanceAssertionOperator,
            status: raw.status,
            comment: raw.comment,
            trailingComments: raw.trailingComments,
        )
    }

    /// One posting per amount, sharing the account, kind and status the elided
    /// line wrote, with the fields that belong to the line rather than to an
    /// amount handed to one of them.
    ///
    /// Which one is a question of where the reader would look for it. The
    /// inline comment sat at the end of the first line and the full-line
    /// comments sat under the last, so they go there. A balance assertion
    /// names a commodity and belongs to the posting in that commodity, falling
    /// back to the first when it names one the line did not absorb, since the
    /// assertion is preserved and never checked either way. A price on a line
    /// that wrote no amount prices nothing, and stays on the first posting,
    /// which is where it was before an elision could expand.
    static func postings(from raw: RawPosting, amounts: [Amount]) -> [Posting] {
        guard amounts.count > 1 else { return amounts.map { posting(from: raw, amount: $0) } }
        let assertionIndex = raw.balanceAssertion
            .flatMap { assertion in amounts.firstIndex { $0.commodity == assertion.commodity } } ?? 0
        return amounts.enumerated().map { index, amount in
            Posting(
                accountName: raw.accountName,
                kind: raw.kind,
                amount: amount,
                price: index == 0 ? raw.price : nil,
                balanceAssertion: index == assertionIndex ? raw.balanceAssertion : nil,
                balanceAssertionOperator: raw.balanceAssertionOperator,
                status: raw.status,
                comment: index == 0 ? raw.comment : nil,
                trailingComments: index == amounts.count - 1 ? raw.trailingComments : [],
            )
        }
    }
}
