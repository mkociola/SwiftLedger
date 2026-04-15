import Foundation

/// ISO 4217 currency code (e.g. "USD", "EUR", "PLN").
public typealias CurrencyCode = String

/// An immutable monetary amount paired with a currency.
///
/// Uses `Decimal` internally to avoid floating-point rounding errors.
public struct Money: Sendable, Codable, Hashable, CustomStringConvertible {
    public let amount: Decimal
    public let currency: CurrencyCode

    public init(_ amount: Decimal, _ currency: CurrencyCode) {
        let upper = currency.uppercased()
        precondition(
            upper.count == 3 && upper.allSatisfy(\.isLetter),
            "Invalid currency code '\(currency)': must be a 3-letter ISO 4217 code (e.g. \"USD\")"
        )
        self.amount = amount
        self.currency = upper
    }

    public var isZero: Bool { amount == .zero }

    public var description: String { "\(amount) \(currency)" }
}

// MARK: - Arithmetic

extension Money {
    /// Adds two money values. Throws if currencies differ.
    public static func + (lhs: Money, rhs: Money) throws -> Money {
        guard lhs.currency == rhs.currency else {
            throw LedgerError.currencyMismatch(lhs, rhs)
        }
        return Money(lhs.amount + rhs.amount, lhs.currency)
    }

    /// Subtracts two money values. Throws if currencies differ.
    public static func - (lhs: Money, rhs: Money) throws -> Money {
        guard lhs.currency == rhs.currency else {
            throw LedgerError.currencyMismatch(lhs, rhs)
        }
        return Money(lhs.amount - rhs.amount, lhs.currency)
    }

    /// Multiplies a monetary amount by a scalar.
    public static func * (lhs: Money, rhs: Decimal) -> Money {
        Money(lhs.amount * rhs, lhs.currency)
    }

    /// Returns the negation of this amount (same currency, negated amount).
    public var negated: Money { Money(-amount, currency) }
}

// MARK: - Comparable

extension Money: Comparable {
    /// Compares two monetary amounts.
    /// - Precondition: Both values must share the same currency.
    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(
            lhs.currency == rhs.currency,
            "Cannot compare Money values of different currencies: \(lhs.currency) vs \(rhs.currency)"
        )
        return lhs.amount < rhs.amount
    }
}

// MARK: - Helpers

extension Collection where Element == Money {
    /// Sums all money values in the collection.
    /// - Precondition: All elements share the same currency.
    /// - Returns: `nil` if the collection is empty.
    func sum() throws -> Money? {
        guard let first = self.first else { return nil }
        return try self.dropFirst().reduce(first) { try $0 + $1 }
    }
}
