import Foundation

/// An account balance entry used in reports.
public struct AccountBalance: Sendable {
    public let account: Account
    /// Net amounts, one entry per commodity.
    public let amounts: [Amount]

    public init(account: Account, amounts: [Amount]) {
        self.account = account
        self.amounts = amounts
    }

    /// Returns the net quantity for a given commodity, or `nil` if not present.
    public func quantity(for commodity: String) -> Decimal? {
        amounts.first { $0.commodity == commodity }?.quantity
    }
}
