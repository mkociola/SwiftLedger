import Foundation

/// A named account in the chart of accounts.
public struct Account: Sendable, Hashable {
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
        let upper = currency.uppercased()
        precondition(
            upper.count == 3 && upper.allSatisfy(\.isLetter),
            "Invalid currency code '\(currency)': must be a 3-letter ISO 4217 code (e.g. \"USD\")"
        )
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.currency = upper
    }
}

// MARK: - Identifiable

extension Account: Identifiable {}

// MARK: - Codable

extension Account: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, type, description, currency }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id          = try container.decode(UUID.self,        forKey: .id)
        let name        = try container.decode(String.self,      forKey: .name)
        let type        = try container.decode(AccountType.self, forKey: .type)
        let description = try container.decode(String.self,      forKey: .description)
        let currency    = try container.decode(String.self,      forKey: .currency)
        let upper = currency.uppercased()
        guard upper.count == 3 && upper.allSatisfy(\.isLetter) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currency, in: container,
                debugDescription: "Invalid currency code '\(currency)': must be 3 letters (ISO 4217)"
            )
        }
        self.id          = id
        self.name        = name
        self.type        = type
        self.description = description
        self.currency    = upper
    }
}
