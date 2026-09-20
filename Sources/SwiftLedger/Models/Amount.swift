import Foundation

/// A monetary amount paired with an arbitrary commodity symbol.
///
/// Commodities are free-form strings: ISO codes ("USD", "EUR"), currency
/// symbols ("$", "£", "€"), ticker symbols ("BTC", "AAPL"), or any other
/// PTA-compatible commodity identifier.
///
/// Amounts carry their original formatting style (prefix vs. suffix commodity)
/// so that serialised output matches the source journal.
public struct Amount: Sendable, Codable, Hashable, CustomStringConvertible {
    /// The signed quantity. Positive = inflow to the account; negative = outflow.
    public let quantity: Decimal
    /// Commodity identifier: "USD", "$", "BTC", etc.
    public let commodity: String
    /// `true` if the commodity symbol precedes the number (e.g. `$100`);
    /// `false` if it follows (e.g. `100 USD`).
    public let commodityIsPrefix: Bool

    public init(quantity: Decimal, commodity: String, commodityIsPrefix: Bool = false) {
        self.quantity = quantity
        self.commodity = commodity
        self.commodityIsPrefix = commodityIsPrefix
    }

    public var isZero: Bool {
        quantity == .zero
    }

    public var negated: Amount {
        Amount(quantity: -quantity, commodity: commodity, commodityIsPrefix: commodityIsPrefix)
    }

    public var description: String {
        commodityIsPrefix ? "\(commodity)\(quantity)" : "\(quantity) \(commodity)"
    }
}

/// The order every multi-commodity answer in this library comes back in.
///
/// hledger orders a journal's commodities by the name itself. A name with a
/// space in it is quoted where the file writes it, only so that the parser can
/// see where the name ends, and SwiftLedger keeps those quotes in the symbol
/// because the symbol is also what gets written back. Sorting the symbol as it
/// stands would therefore order `"AAPL 2026"` by its opening quote, which
/// falls before `$`, while hledger orders it by its `A`, which falls after.
/// Every sort that claims to be in commodity order asks this instead, so that
/// an elided line expands, a residual reads and a picker lists in the one
/// order.
enum CommodityOrder {
    /// Whether `lhs` comes first.
    ///
    /// Two symbols that differ only in their quotes are separated by the
    /// symbols themselves, so that the order is still total and a journal
    /// holding both `X` and `"X"` sorts the same way twice.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let (left, right) = (key(of: lhs), key(of: rhs))
        return left == right ? lhs < rhs : left < right
    }

    /// The symbol without the quotes a file wraps a spaced name in.
    static func key(of commodity: String) -> Substring {
        guard commodity.count >= 2, commodity.hasPrefix("\""), commodity.hasSuffix("\"") else {
            return commodity[...]
        }
        return commodity.dropFirst().dropLast()
    }
}

// MARK: - Arithmetic

public extension Amount {
    /// Adds two amounts. Precondition: commodities must match.
    static func + (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.commodity == rhs.commodity,
                     "Cannot add amounts with different commodities: \(lhs.commodity) + \(rhs.commodity)")
        return Amount(quantity: lhs.quantity + rhs.quantity,
                      commodity: lhs.commodity,
                      commodityIsPrefix: lhs.commodityIsPrefix)
    }

    /// Subtracts two amounts. Precondition: commodities must match.
    static func - (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.commodity == rhs.commodity,
                     "Cannot subtract amounts with different commodities: \(lhs.commodity) - \(rhs.commodity)")
        return Amount(quantity: lhs.quantity - rhs.quantity,
                      commodity: lhs.commodity,
                      commodityIsPrefix: lhs.commodityIsPrefix)
    }

    /// Multiplies by a scalar.
    static func * (lhs: Amount, rhs: Decimal) -> Amount {
        Amount(quantity: lhs.quantity * rhs,
               commodity: lhs.commodity,
               commodityIsPrefix: lhs.commodityIsPrefix)
    }
}

public extension Collection<Amount> {
    /// Groups amounts by commodity and returns one net `Amount` per commodity.
    /// Zero-value amounts are included.
    func netByCommodity() -> [Amount] {
        var sums: [String: (Decimal, Bool)] = [:]
        for amount in self {
            let current = sums[amount.commodity, default: (.zero, amount.commodityIsPrefix)]
            sums[amount.commodity] = (current.0 + amount.quantity, amount.commodityIsPrefix)
        }
        return sums
            .map { Amount(quantity: $0.value.0, commodity: $0.key, commodityIsPrefix: $0.value.1) }
            .sorted { CommodityOrder.precedes($0.commodity, $1.commodity) }
    }
}
