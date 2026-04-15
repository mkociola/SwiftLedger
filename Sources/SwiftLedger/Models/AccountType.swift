import Foundation

/// The five standard account types in double-entry bookkeeping, plus
/// `.unclassified` for accounts whose name does not follow a recognised convention.
public enum AccountType: String, Sendable, Codable, Hashable, CaseIterable {
    /// Economic resources (e.g. Cash, Inventory). Normal balance: positive.
    case asset
    /// Obligations owed (e.g. Loans, Accounts Payable). Normal balance: negative.
    case liability
    /// Owner's residual interest (e.g. Retained Earnings). Normal balance: negative.
    case equity
    /// Income earned (e.g. Sales, Service Income). Normal balance: negative.
    case revenue
    /// Costs incurred (e.g. Rent, Salaries). Normal balance: positive.
    case expense
    /// Root account name did not match any recognised convention.
    case unclassified
}

extension AccountType {
    /// Infers the account type from the top-level segment of the account name.
    ///
    /// Matching is case-insensitive and covers common English conventions:
    ///
    /// | Root                     | Type          |
    /// |--------------------------|---------------|
    /// | assets / asset           | `.asset`      |
    /// | liabilities / liability  | `.liability`  |
    /// | equity / equities        | `.equity`     |
    /// | income / revenue         | `.revenue`    |
    /// | expenses / expense       | `.expense`    |
    /// | (anything else)          | `.unclassified` |
    public static func inferred(from accountName: String) -> AccountType {
        let root = accountName.split(separator: ":").first.map { $0.lowercased() } ?? ""
        switch root {
        case "assets",      "asset":                return .asset
        case "liabilities", "liability":            return .liability
        case "equity",      "equities":             return .equity
        case "income",      "revenue", "revenues":  return .revenue
        case "expenses",    "expense":              return .expense
        default:                                    return .unclassified
        }
    }

    /// The sign multiplier used when displaying this account type in reports.
    ///
    /// - `+1`: display at face value (assets, expenses)
    /// - `-1`: negate for display (liabilities, equity, revenue)
    public var displaySign: Decimal {
        switch self {
        case .asset, .expense, .unclassified: return 1
        case .liability, .equity, .revenue:   return -1
        }
    }
}
