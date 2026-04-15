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
        self.quantity          = quantity
        self.commodity         = commodity
        self.commodityIsPrefix = commodityIsPrefix
    }

    public var isZero: Bool { quantity == .zero }

    public var negated: Amount {
        Amount(quantity: -quantity, commodity: commodity, commodityIsPrefix: commodityIsPrefix)
    }

    public var description: String {
        commodityIsPrefix ? "\(commodity)\(quantity)" : "\(quantity) \(commodity)"
    }
}

// MARK: - Arithmetic

extension Amount {
    /// Adds two amounts. Precondition: commodities must match.
    public static func + (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.commodity == rhs.commodity,
                     "Cannot add amounts with different commodities: \(lhs.commodity) + \(rhs.commodity)")
        return Amount(quantity: lhs.quantity + rhs.quantity,
                      commodity: lhs.commodity,
                      commodityIsPrefix: lhs.commodityIsPrefix)
    }

    /// Subtracts two amounts. Precondition: commodities must match.
    public static func - (lhs: Amount, rhs: Amount) -> Amount {
        precondition(lhs.commodity == rhs.commodity,
                     "Cannot subtract amounts with different commodities: \(lhs.commodity) - \(rhs.commodity)")
        return Amount(quantity: lhs.quantity - rhs.quantity,
                      commodity: lhs.commodity,
                      commodityIsPrefix: lhs.commodityIsPrefix)
    }

    /// Multiplies by a scalar.
    public static func * (lhs: Amount, rhs: Decimal) -> Amount {
        Amount(quantity: lhs.quantity * rhs,
               commodity: lhs.commodity,
               commodityIsPrefix: lhs.commodityIsPrefix)
    }
}

extension Collection where Element == Amount {
    /// Groups amounts by commodity and returns one net `Amount` per commodity.
    /// Zero-value amounts are included.
    public func netByCommodity() -> [Amount] {
        var sums: [String: (Decimal, Bool)] = [:]
        for a in self {
            let current = sums[a.commodity, default: (.zero, a.commodityIsPrefix)]
            sums[a.commodity] = (current.0 + a.quantity, a.commodityIsPrefix)
        }
        return sums
            .map { Amount(quantity: $0.value.0, commodity: $0.key, commodityIsPrefix: $0.value.1) }
            .sorted { $0.commodity < $1.commodity }
    }
}
