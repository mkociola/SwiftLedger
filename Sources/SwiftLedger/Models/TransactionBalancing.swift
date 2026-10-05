import Foundation

/// Whether one balancing group of a transaction balances, and how.
///
/// A transaction has two groups, its real postings and its bracketed ones, and
/// each gets a verdict of its own. Parenthesised postings are in neither.
public enum BalanceVerdict: Sendable, Equatable {
    /// Every commodity nets to zero, to within half of the last decimal place
    /// the entry writes it in.
    case balanced
    /// The group is left in exactly two commodities of opposite sign and
    /// nothing priced: money changed from one into the other. `from` is in the
    /// commodity that appears first, which is the one hledger hangs its
    /// inferred cost on. Neither amount is a cost and nothing is written to
    /// the file for it.
    case exchange(from: Amount, to: Amount) // swiftlint:disable:this identifier_name
    /// What each commodity is off by, in order of first appearance, with a
    /// priced posting counted at what it cost.
    case unbalanced([Amount])
}

/// The fraction digits one posting's numbers have in the file it was read
/// from. `nil` for a number nobody wrote: an inferred amount, or anything
/// built in code.
struct WrittenDigits {
    var amount: Int?
    var price: Int?
}

/// The one place that decides whether postings balance. `Transaction.init`,
/// `JournalParser` and `LedgerManager` all ask here, so an editor that asks
/// the same question cannot be told something a save disagrees with.
///
/// Both rules were measured against hledger 1.52.4.
enum TransactionBalancing {
    /// The verdict for each group of `postings`.
    ///
    /// - Parameters:
    ///   - postings: Every posting of the entry, parenthesised ones included:
    ///     the digits they are written with count.
    ///   - written: The digits the file wrote, index for index with
    ///     `postings`, when the entry came out of the parser.
    ///   - formats: The styles a serializer would write a number with. `nil`
    ///     measures each number at the digits it needs, the loosest a
    ///     code-built entry can be held to.
    static func verdicts(
        of postings: [Posting],
        written: [WrittenDigits]? = nil,
        formats: [String: CommodityFormat]? = nil,
    ) -> (real: BalanceVerdict, bracketed: BalanceVerdict) {
        let places = places(of: postings, written: written, formats: formats)
        return (
            verdict(of: postings.filter { $0.kind == .real }, places: places),
            verdict(of: postings.filter { $0.kind == .balancedVirtual }, places: places),
        )
    }

    /// The last decimal place each commodity is written in: the most digits
    /// among the posting amounts in it, or, for a commodity no posting amount
    /// is in, among the prices in it.
    private static func places(
        of postings: [Posting],
        written: [WrittenDigits]?,
        formats: [String: CommodityFormat]?,
    ) -> [String: Int] {
        func digits(_ amount: Amount, written: Int?) -> Int {
            if let written { return written }
            let format = formats.map { $0[amount.commodity] ?? .default(for: amount.commodity) }
            return (format ?? CommodityFormat()).writtenFractionDigits(of: amount.quantity)
        }
        var amounts: [String: Int] = [:]
        var prices: [String: Int] = [:]
        for (index, posting) in postings.enumerated() {
            let amount = posting.amount
            amounts[amount.commodity] = max(
                amounts[amount.commodity] ?? 0, digits(amount, written: written?[index].amount),
            )
            if let price = posting.price?.amount {
                prices[price.commodity] = max(
                    prices[price.commodity] ?? 0, digits(price, written: written?[index].price),
                )
            }
        }
        return prices.merging(amounts) { _, fromAmounts in fromAmounts }
    }

    private static func verdict(of group: [Posting], places: [String: Int]) -> BalanceVerdict {
        // Step 1: what each posting contributes, a priced one at its cost.
        let residuals = sums(group.map { ($0.balancingAmount.commodity, $0.balancingAmount) })
            .map(\.amount)
            .filter { !isZero($0, places: places) }
        guard !residuals.isEmpty else { return .balanced }

        // Step 2: the amounts as written, keyed by commodity and price. A
        // priced sum goes only when it is exactly zero; an unpriced one goes
        // when rounding calls it zero.
        let left = sums(group.map { (Key(commodity: $0.amount.commodity, price: $0.price), $0.amount) })
            .filter { entry in
                guard entry.key.price != nil else { return !isZero(entry.amount, places: places) }
                return entry.amount.quantity != Decimal.zero
            }
        guard left.count == 2,
              left.allSatisfy({ $0.key.price == nil }),
              (left[0].amount.quantity < 0) != (left[1].amount.quantity < 0)
        else { return .unbalanced(residuals) }

        // The priced postings have to cancel in what they cost as well as in
        // what they moved. A per-unit price that nets to no quantity costs
        // nothing; a total price is charged in full on every posting that
        // carries it, so `4 AAPL @@ 1500 USD`, `6 AAPL @@ 1500 USD` and
        // `-10 AAPL @@ 1500 USD` move nothing and still cost 1500.
        let costs = sums(group.filter { $0.price != nil }.map { ($0.balancingAmount.commodity, $0.balancingAmount) })
        guard costs.allSatisfy({ isZero($0.amount, places: places) }) else { return .unbalanced(residuals) }
        return .exchange(from: left[0].amount, to: left[1].amount)
    }

    private struct Key: Hashable {
        var commodity: String
        var price: PostingPrice?
    }

    /// Sums amounts per key, in order of first appearance. Each sum keeps the
    /// commodity spelling of the first amount under its key.
    private static func sums<K: Hashable>(_ entries: [(K, Amount)]) -> [(key: K, amount: Amount)] {
        var order: [K] = []
        var totals: [K: Amount] = [:]
        for (key, amount) in entries {
            guard let total = totals[key] else {
                order.append(key)
                totals[key] = amount
                continue
            }
            totals[key] = Amount(
                quantity: total.quantity + amount.quantity,
                commodity: total.commodity,
                commodityIsPrefix: total.commodityIsPrefix,
            )
        }
        return order.compactMap { key in totals[key].map { (key, $0) } }
    }

    /// At most half a unit of the last place the entry writes the commodity
    /// in, the boundary included. A commodity with no place on record has to
    /// be exactly zero.
    private static func isZero(_ amount: Amount, places: [String: Int]) -> Bool {
        // `Decimal.nan` compares below everything, so it would pass the test
        // underneath. It is never zero.
        guard !amount.quantity.isNaN else { return false }
        guard let place = places[amount.commodity] else { return amount.quantity == .zero }
        return abs(amount.quantity) * 2 <= Decimal(sign: .plus, exponent: -place, significand: 1)
    }
}

extension CommodityFormat {
    /// How many fraction digits `render(_:)` writes `quantity` with. Counted
    /// off what `render` produces, so the balance check and the file cannot
    /// drift apart.
    func writtenFractionDigits(of quantity: Decimal) -> Int {
        let text = render(abs(quantity))
        guard let mark = text.lastIndex(of: decimalMark) else { return 0 }
        return text.distance(from: mark, to: text.endIndex) - 1
    }
}

public extension Transaction {
    /// Whether `postings` balance, per group, without throwing: what an editor
    /// asks on every keystroke.
    ///
    /// - Parameters:
    ///   - postings: Every posting of the draft, parenthesised ones included.
    ///   - formats: The styles the journal writes numbers with. Pass the
    ///     journal's `commodityFormats` to get the answer a save gives. `nil`
    ///     measures each number at the digits it needs.
    static func balance(
        of postings: [Posting],
        formats: [String: CommodityFormat]? = nil,
    ) -> (real: BalanceVerdict, bracketed: BalanceVerdict) {
        TransactionBalancing.verdicts(of: postings, formats: formats)
    }
}
