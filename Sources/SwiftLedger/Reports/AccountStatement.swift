import Foundation

/// A line in an account statement with a running balance.
public struct AccountStatementLine: Sendable, Codable, Hashable {
    public let transaction: Transaction
    /// The entry for this account within the transaction.
    public let entry: Entry
    /// Running balance after this line (on the account's normal side).
    public let runningBalance: Money
}

/// A chronological statement of all activity for a single account,
/// including a running balance after each transaction.
public struct AccountStatement: Sendable, Codable {
    public let account: Account
    public let periodStart: Date?
    public let periodEnd: Date?
    public let lines: [AccountStatementLine]

    /// The closing balance (last running balance, or zero if no transactions).
    public var closingBalance: Money {
        lines.last?.runningBalance ?? Money(.zero, account.currency)
    }

    // MARK: - Init

    public init(
        ledger: Ledger,
        accountID: UUID,
        from start: Date? = nil,
        to end: Date? = nil
    ) throws {
        let account = try ledger.chartOfAccounts.account(id: accountID)
        self.account = account
        self.periodStart = start
        self.periodEnd = end

        var txns = ledger.journal.transactions(for: accountID)
        if let start { txns = txns.filter { $0.date >= start } }
        if let end   { txns = txns.filter { $0.date <= end } }
        txns.sort { $0.date < $1.date }

        var running = Decimal.zero
        self.lines = txns.compactMap { tx -> AccountStatementLine? in
            guard let entry = tx.entries.first(where: { $0.account.id == accountID }) else {
                return nil
            }
            // Increase running balance when on the normal side, decrease otherwise.
            if entry.side == account.type.normalBalanceSide {
                running += entry.amount.amount
            } else {
                running -= entry.amount.amount
            }
            return AccountStatementLine(
                transaction: tx,
                entry: entry,
                runningBalance: Money(running, account.currency)
            )
        }
    }
}
