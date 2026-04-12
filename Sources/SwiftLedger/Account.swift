import Foundation

/// A named account in the chart of accounts.
public struct Account: Sendable, Codable, Hashable {
    /// Stable unique identifier.
    public let id: UUID
    /// Human-readable account name (e.g. "Cash", "Accounts Receivable").
    public let name: String
    /// The fundamental accounting category.
    public let type: AccountType
    /// Optional description or notes.
    public let description: String
    /// ISO 4217 currency code for this account.
    public let currency: CurrencyCode

    public init(
        id: UUID = UUID(),
        name: String,
        type: AccountType,
        description: String = "",
        currency: CurrencyCode
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.currency = currency.uppercased()
    }
}

// MARK: - Identifiable

extension Account: Identifiable {}
