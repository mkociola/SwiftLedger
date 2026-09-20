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
    /// posting per commodity with something left to absorb, sitting where the
    /// elided line was, in commodity order rather than in the order the entry
    /// happens to write them. That is what ledger and hledger infer, and
    /// commodity order is how hledger prints the entry back: it is also the
    /// order every multi-commodity answer in this library comes in, so an
    /// entry and a balance list their commodities the same way round.
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
    func resolveElisions(_ rawPostings: [RawPosting]) throws -> [Posting] {
        var fills: [Posting.Kind: [Amount]] = [:]
        for kind in [Posting.Kind.real, .balancedVirtual] {
            let group = rawPostings.filter { $0.kind == kind }
            let elided = group.count(where: { $0.amount == nil })
            guard elided <= 1 else { throw LedgerError.multipleElidedPostings }
            if elided == 1 { fills[kind] = try remainders(of: group, in: rawPostings) }
        }

        return try rawPostings.flatMap { raw -> [Posting] in
            if let amount = raw.amount { return [Self.posting(from: raw, amount: amount)] }
            if raw.kind == .virtual {
                return try [Self.posting(from: raw, amount: zeroAmount(matching: rawPostings))]
            }
            guard let fill = fills[raw.kind], !fill.isEmpty else {
                throw LedgerError.cannotResolveElision
            }
            return Self.postings(from: raw, amounts: fill)
        }
    }

    /// What the one posting of a group that elided its amount takes: minus the
    /// sum of what the rest of its own group wrote, one amount per commodity
    /// that does not already net to zero, in commodity order. A priced posting
    /// contributes what it cost, not what it moved, so that a share purchase
    /// can balance an elided cash leg. A group in which nobody wrote an amount
    /// leaves zero to absorb, in the first commodity the entry writes (see
    /// `zeroAmount(matching:)`, which is where file order decides).
    ///
    /// A group whose written amounts already balance leaves one zero rather
    /// than nothing, in the first commodity written, so that the line the user
    /// wrote is still a posting. Only commodities past the first are dropped
    /// when they net out: an entry does not need a `0` leg per commodity to
    /// say what it already said.
    func remainders(of group: [RawPosting], in transaction: [RawPosting]) throws -> [Amount] {
        let written = group.compactMap { raw in
            raw.amount.map { raw.price?.cost(of: $0.quantity) ?? $0 }
        }
        guard let first = written.first else { return try [zeroAmount(matching: transaction)] }

        var sums: [String: (quantity: Decimal, isPrefix: Bool)] = [:]
        for amount in written {
            let running = sums[amount.commodity, default: (.zero, amount.commodityIsPrefix)]
            sums[amount.commodity] = (running.quantity + amount.quantity, running.isPrefix)
        }

        let remainders = sums
            .compactMap { commodity, sum -> Amount? in
                guard sum.quantity != .zero else { return nil }
                return Amount(
                    quantity: -sum.quantity, commodity: commodity, commodityIsPrefix: sum.isPrefix,
                )
            }
            .sorted { $0.commodity < $1.commodity }
        guard remainders.isEmpty else { return remainders }
        return [Amount(
            quantity: .zero, commodity: first.commodity, commodityIsPrefix: first.commodityIsPrefix,
        )]
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

    /// One posting from one written line, carrying the digits the line wrote.
    ///
    /// `amount` is handed in rather than read off `raw` because an elided line
    /// has none of its own, and what it absorbs was inferred rather than
    /// written: such a posting keeps `raw`'s price scale and no amount scale,
    /// since there are no digits in the file to measure.
    static func posting(from raw: RawPosting, amount: Amount) -> Posting {
        Posting(
            accountName: raw.accountName,
            kind: raw.kind,
            amount: amount,
            price: raw.price,
            balanceAssertion: raw.balanceAssertion,
            status: raw.status,
            comment: raw.comment,
            trailingComments: raw.trailingComments,
        )
        .taggedWithScales(amount: raw.amount == nil ? nil : raw.amountScale, price: raw.priceScale)
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
                status: raw.status,
                comment: index == 0 ? raw.comment : nil,
                trailingComments: index == amounts.count - 1 ? raw.trailingComments : [],
            )
            .taggedWithScales(amount: nil, price: index == 0 ? raw.priceScale : nil)
        }
    }
}
