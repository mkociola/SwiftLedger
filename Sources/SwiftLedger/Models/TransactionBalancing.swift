import Foundation

/// What a transaction's postings leave over once every cost has been applied.
///
/// A transaction balances when each balancing group nets to zero in every
/// commodity, and the two groups are weighed apart: the real postings among
/// themselves, the bracketed ones among themselves, and the parenthesised ones
/// not at all. A posting that carries a price counts as what it cost rather
/// than as what it moved (`Posting.balancingAmount`), which is what lets a
/// trade written in two commodities net to zero.
///
/// "Nets to zero" is not exact arithmetic, and it cannot be: a cash leg
/// rounded to the cent against a foreign amount converted at five decimal
/// places leaves a residual no journal could write away. hledger reads a
/// residual as zero when it is too small to be written at the precision the
/// entry itself uses for that commodity, and that is the rule here, so a
/// journal hledger loads loads. `residual` is what is left after that reading,
/// which makes it the number to show someone who is still typing an entry:
/// what the empty line has to absorb, negated.
///
/// A group left over in exactly two commodities of opposite sign is the shape
/// hledger reads as an exchange and balances by inferring what one commodity
/// cost in the other. That reading is reported in `Group.conversion` and is
/// never written into the postings: the file says what the user wrote, and
/// plain `hledger print` does not write an inferred cost either.
///
/// Nothing here converts between commodities or sums across them. Every
/// answer is a list of amounts, one per commodity, in commodity order.
public struct TransactionBalance: Sendable, Hashable {
    /// What one balancing group leaves over.
    public struct Group: Sendable, Hashable {
        /// What the group is off by: one amount per commodity, in commodity
        /// order, after costs, with every commodity that nets to zero left
        /// out.
        ///
        /// Empty for a group that balances. A commodity whose residual is
        /// smaller than the entry can write is counted as zero and left out
        /// with the rest.
        public let residual: [Amount]

        /// The exchange hledger would read into this group, or `nil` when
        /// there is none to read.
        ///
        /// Non-nil exactly when `residual` is a two-commodity pair of
        /// opposite sign and no posting of the group writes a price of its
        /// own. Such a group balances: the residual is what one side cost, not
        /// what the entry is missing.
        public let conversion: Conversion?

        /// Whether this group balances, outright or by conversion.
        public var isBalanced: Bool {
            residual.isEmpty || conversion != nil
        }
    }

    /// One commodity exchanged for another, at the rate the entry implies.
    ///
    /// This is a reading of the postings and nothing else: computed on demand,
    /// never stored on a `Posting`, never serialised. An editor showing
    /// someone what they are about to record wants all four fields, since a
    /// mistyped amount balances in silence and only the rate gives it away.
    public struct Conversion: Sendable, Hashable {
        /// The postings the cost belongs to: every posting of the group
        /// written in the commodity being priced, as indices into the array
        /// handed to `Transaction.balance(of:)`.
        ///
        /// hledger prices the commodity of the first such posting in the
        /// group, and prices every posting in it, including one whose own
        /// sign runs against the net.
        public let postingIndices: [Int]

        /// What those postings cost: `.total` when one posting carries the
        /// whole exchange, `.perUnit` when several share it, which is the
        /// spelling hledger chooses. The rate is exact, so a rate that does
        /// not terminate is as exact as `Decimal` can hold; only a display
        /// rounds it.
        public let price: PostingPrice

        /// The net of the commodity being priced, signed.
        public let from: Amount

        /// The net of the commodity it is priced in, signed, and of the
        /// opposite sign to `from`.
        public let to: Amount // swiftlint:disable:this identifier_name
    }

    /// The postings written bare, which are the transaction proper.
    public let real: Group

    /// The postings written in brackets, which balance among themselves.
    public let balancedVirtual: Group

    /// Whether both groups balance. Parenthesised postings belong to neither
    /// and take no part in this, which is the whole point of the parentheses.
    public var isBalanced: Bool {
        real.isBalanced && balancedVirtual.isBalanced
    }
}

// MARK: - Asking a transaction whether it balances

public extension Transaction {
    /// What `postings` leave over, without building a transaction and without
    /// throwing.
    ///
    /// This is the one implementation of the rule. `Transaction.init` throws
    /// on what it reports, the parser reaches it through `init`, and
    /// `LedgerManager` asks it again with the journal's own styles before
    /// anything is written, so an editor that drives itself from this and the
    /// file that comes out of a save can never disagree about what balances.
    ///
    /// `commodityFormats` is the journal's house style, from
    /// `Journal.commodityFormats`. It decides how many digits a posting nobody
    /// has written yet will be written with, which is what the next parse will
    /// measure the tolerance against. A caller with no journal to hand can
    /// leave it out and gets `CommodityFormat.default(for:)`, which is what
    /// `Transaction.init` itself uses.
    static func balance(
        of postings: [Posting],
        commodityFormats: [String: CommodityFormat] = [:],
    ) -> TransactionBalance {
        TransactionBalance(
            real: TransactionBalancing.group(
                .real, of: postings, formats: commodityFormats,
            ),
            balancedVirtual: TransactionBalancing.group(
                .balancedVirtual, of: postings, formats: commodityFormats,
            ),
        )
    }

    /// What this transaction leaves over, in the styles a journal built in
    /// code would write.
    ///
    /// A transaction that exists balances already, so this is here for what it
    /// says about *how*: which commodities a caller is looking at, and what an
    /// editor should put in front of someone about to change one of them.
    var balance: TransactionBalance {
        Self.balance(of: postings)
    }
}

// MARK: - The rule itself

/// The balancing rule, in one place.
///
/// Internal: callers reach it through `Transaction.balance(of:)`, which is the
/// name the rule is documented under.
enum TransactionBalancing {
    /// What the postings of one group leave over.
    ///
    /// `postings` is the whole transaction rather than the group alone,
    /// because the tolerance is read from every posting the entry writes: a
    /// bracketed line written to four places tightens the real postings' own
    /// reading, which is hledger's behaviour, measured.
    static func group(
        _ kind: Posting.Kind,
        of postings: [Posting],
        formats: [String: CommodityFormat],
    ) -> TransactionBalance.Group {
        let members = postings.indices.filter { postings[$0].kind == kind }
        let left = residual(
            of: members.map { postings[$0] }, in: postings, formats: formats,
        )
        return TransactionBalance.Group(
            residual: left,
            conversion: conversion(for: left, over: members, in: postings),
        )
    }

    /// The exchange hledger would read into what a group is left with.
    ///
    /// Two commodities of opposite sign and no price written anywhere in the
    /// group: then the entry is an exchange and the residual is the two sides
    /// of it. The rate is exact, `|other net| / |priced net|`, and the cost is
    /// attached to every posting written in the commodity of the group's first
    /// posting in either of the two, which is what makes an entry whose first
    /// leg is the dollar one price the dollars.
    ///
    /// Everything else refuses, as hledger does: three commodities left over,
    /// two of the same sign, or a price still standing once the group's sums
    /// are taken, which switches the reading off for the whole group even when
    /// what it is written on has nothing to do with what is left over. An
    /// elided posting switches it off too, by absorbing the residual before
    /// this is ever asked, which is why the parser resolves elision first.
    static func conversion(
        for residual: [Amount],
        over members: [Int],
        in postings: [Posting],
    ) -> TransactionBalance.Conversion? {
        guard residual.count == 2,
              everyWrittenPriceNetsOut(over: members, in: postings),
              (residual[0].quantity > 0) != (residual[1].quantity > 0),
              let leading = members.first(where: { member in
                  residual.contains { $0.commodity == postings[member].amount.commodity }
              })
        else { return nil }

        let priced = postings[leading].amount.commodity
        let from = residual[0].commodity == priced ? residual[0] : residual[1]
        // swiftlint:disable:next identifier_name
        let to = residual[0].commodity == priced ? residual[1] : residual[0]
        let indices = members.filter { postings[$0].amount.commodity == priced }
        let rate = indices.count == 1
            ? abs(to.quantity)
            : abs(to.quantity) / abs(from.quantity)
        let cost = Amount(
            quantity: rate, commodity: to.commodity, commodityIsPrefix: to.commodityIsPrefix,
        )
        return TransactionBalance.Conversion(
            postingIndices: indices,
            price: indices.count == 1 ? .total(cost) : .perUnit(cost),
            from: from,
            to: to,
        )
    }

    /// Whether every price the group wrote has cancelled out of its sums.
    ///
    /// hledger reads this off what the group adds up to rather than off its
    /// lines: the postings are summed by commodity and by the price each one
    /// wrote, a sum of zero drops out of the reckoning, and the exchange is
    /// refused only when a price is still standing among what is left. So a
    /// share transfer recorded beside a currency exchange leaves the exchange
    /// its inferred cost, because its two legs cancel and take their shared
    /// price with them, while two legs priced differently do not cancel and do
    /// refuse it. Both readings are hledger 1.52.4's, measured.
    ///
    /// A zero here is an exact zero, not a residual small enough to ignore:
    /// the tolerance is about what an entry could have written away, and a
    /// price either cancels or it does not.
    private static func everyWrittenPriceNetsOut(over members: [Int], in postings: [Posting]) -> Bool {
        var sums: [PricedCommodity: Decimal] = [:]
        for member in members {
            let posting = postings[member]
            guard let price = posting.price else { continue }
            let key = PricedCommodity(commodity: posting.amount.commodity, price: price)
            sums[key, default: .zero] += posting.amount.quantity
        }
        return sums.values.allSatisfy { $0 == .zero }
    }

    /// One commodity as one price spells it, which is the key hledger sums a
    /// group's postings under.
    private struct PricedCommodity: Hashable {
        let commodity: String
        let price: PostingPrice
    }

    /// The per-commodity sum of what the group's postings contribute, with the
    /// commodities that net to zero dropped.
    static func residual(
        of members: [Posting],
        in postings: [Posting],
        formats: [String: CommodityFormat],
    ) -> [Amount] {
        var sums: [String: (quantity: Decimal, isPrefix: Bool)] = [:]
        for posting in members {
            let contribution = posting.balancingAmount
            let running = sums[
                contribution.commodity,
                default: (.zero, contribution.commodityIsPrefix),
            ]
            sums[contribution.commodity] = (running.quantity + contribution.quantity, running.isPrefix)
        }
        return sums
            .compactMap { commodity, sum -> Amount? in
                let allowed = tolerance(for: commodity, in: postings, formats: formats)
                guard abs(sum.quantity) > allowed else { return nil }
                return Amount(
                    quantity: sum.quantity, commodity: commodity, commodityIsPrefix: sum.isPrefix,
                )
            }
            .sorted { CommodityOrder.precedes($0.commodity, $1.commodity) }
    }

    /// The largest residual in `commodity` that still counts as zero.
    ///
    /// Half of the last place the entry writes that commodity in, the boundary
    /// included: at two decimal places a residual of 0.0050 balances and
    /// 0.0051 does not. The place is read from the entry's own amounts, so one
    /// posting written to four places tightens the whole entry, and it is read
    /// from every posting the entry carries whatever group it is in, since
    /// that is what hledger 1.52.4 does when measured.
    ///
    /// Prices and balance assertions are not amounts the entry is claiming to
    /// hold, and neither one counts, again as measured. A commodity the entry
    /// writes no plain amount in at all, one reached only through a price, has
    /// nothing else to be measured by and is measured by its rates.
    ///
    /// A declared `commodity` directive deliberately has no say: it states how
    /// to display an amount, and under hledger's default balancing it does not
    /// move this boundary.
    static func tolerance(
        for commodity: String,
        in postings: [Posting],
        formats: [String: CommodityFormat],
    ) -> Decimal {
        let written = postings.compactMap { posting -> Int? in
            guard posting.amount.commodity == commodity else { return nil }
            return posting.amountScale ?? writtenScale(of: posting.amount, formats: formats)
        }
        let scale = written.max() ?? rateScale(for: commodity, in: postings, formats: formats) ?? 0
        // Decimal cannot hold every exponent a pathological file could ask
        // for, and a hundred and twenty places is already far past anything a
        // journal writes: past it, the residual is simply required to be zero.
        let places = min(max(scale, 0), 120)
        return Decimal(sign: .plus, exponent: -(places + 1), significand: 5)
    }

    /// The places the entry's rates in `commodity` were written to, for a
    /// commodity no posting holds an amount in.
    private static func rateScale(
        for commodity: String,
        in postings: [Posting],
        formats: [String: CommodityFormat],
    ) -> Int? {
        postings.compactMap { posting -> Int? in
            guard let price = posting.price, price.amount.commodity == commodity else { return nil }
            return posting.priceScale ?? writtenScale(of: price.amount, formats: formats)
        }.max()
    }

    /// How many digits this amount is written with: the digits the file wrote
    /// where the file wrote it, and otherwise the digits the serializer will
    /// write for it in this journal.
    ///
    /// The second half is what keeps a transaction built in code from being
    /// saved into a file that will not load again. The next parse measures the
    /// digits it finds on the line, so the tolerance an unwritten amount is
    /// held to has to be the one its written form will earn, which is why this
    /// and `JournalSerializer` both ask `CommodityFormat.render`.
    static func writtenScale(of amount: Amount, formats: [String: CommodityFormat]) -> Int {
        let format = formats[amount.commodity] ?? .default(for: amount.commodity)
        return format.writtenFractionDigits(of: amount.quantity)
    }
}
