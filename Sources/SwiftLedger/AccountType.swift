/// The five fundamental account types in double-entry bookkeeping.
public enum AccountType: String, Sendable, Codable, Hashable, CaseIterable {
    /// Economic resources owned or controlled (e.g. cash, inventory). Normal debit balance.
    case asset
    /// Obligations owed to external parties (e.g. loans, accounts payable). Normal credit balance.
    case liability
    /// Owner's residual interest in assets after liabilities (e.g. retained earnings). Normal credit balance.
    case equity
    /// Income earned from business activities (e.g. sales). Normal credit balance.
    case revenue
    /// Costs incurred to generate revenue (e.g. rent, salaries). Normal debit balance.
    case expense
}

extension AccountType {
    /// The side of the ledger that increases this account type.
    public var normalBalanceSide: EntrySide {
        switch self {
        case .asset, .expense: .debit
        case .liability, .equity, .revenue: .credit
        }
    }
}
