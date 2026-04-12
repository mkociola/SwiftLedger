import Foundation

/// The computed balance for a single account.
public struct AccountBalance: Sendable, Codable, Hashable {
    public let account: Account
    /// Sum of all debit entries posted to this account.
    public let debitTotal: Money
    /// Sum of all credit entries posted to this account.
    public let creditTotal: Money

    /// The net balance expressed on the account's normal balance side.
    ///
    /// - Positive: the account has a balance on its normal side.
    /// - Negative: the account has a balance on the opposite side (abnormal).
    public var netBalance: Money {
        switch account.type.normalBalanceSide {
        case .debit:
            Money(debitTotal.amount - creditTotal.amount, account.currency)
        case .credit:
            Money(creditTotal.amount - debitTotal.amount, account.currency)
        }
    }

    internal init(account: Account, debitTotal: Money, creditTotal: Money) {
        self.account = account
        self.debitTotal = debitTotal
        self.creditTotal = creditTotal
    }
}
