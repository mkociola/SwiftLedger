/// An account inferred from or declared in a journal.
///
/// Accounts are identified purely by their name (e.g. `"Expenses:Food:Groceries"`).
/// There is no mandatory pre-registration — accounts are derived automatically
/// from posting account names.
public struct Account: Sendable, Codable, Hashable {
    /// Full account name (e.g. `"Assets:Checking"`, `"Expenses:Food:Groceries"`).
    public let name: String
    /// The accounting category, inferred from the name root or set explicitly.
    public let type: AccountType

    public init(name: String, type: AccountType? = nil) {
        self.name = name
        self.type = type ?? AccountType.inferred(from: name)
    }

    /// The immediate parent account name, or `nil` if this is a top-level account.
    ///
    ///     Account(name: "Expenses:Food:Groceries").parent // "Expenses:Food"
    public var parent: String? {
        guard let idx = name.lastIndex(of: ":") else { return nil }
        return String(name[..<idx])
    }

    /// The short name of the account (the last segment after the final `:`).
    ///
    ///     Account(name: "Expenses:Food:Groceries").shortName // "Groceries"
    public var shortName: String {
        guard let idx = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: idx)...])
    }
}
