import Foundation

/// An ordered, append-only registry of all accounts used in the ledger.
///
/// Accounts are identified by their `UUID`. Adding an account with a
/// duplicate `id` throws `LedgerError.duplicateAccount`.
public struct ChartOfAccounts: Sendable, Codable, Hashable {
    private var accounts: [UUID: Account] = [:]

    public init() {}

    // MARK: - Mutation

    /// Adds an account to the chart.
    /// - Throws: `LedgerError.duplicateAccount` if the `id` is already registered.
    public mutating func add(_ account: Account) throws {
        guard accounts[account.id] == nil else {
            throw LedgerError.duplicateAccount(account)
        }
        accounts[account.id] = account
    }

    /// Removes an account from the chart.
    /// - Returns: The removed account, or `nil` if it wasn't present.
    @discardableResult
    public mutating func remove(id: UUID) -> Account? {
        accounts.removeValue(forKey: id)
    }

    // MARK: - Queries

    /// Looks up an account by its UUID.
    /// - Throws: `LedgerError.accountNotFound` if not present.
    public func account(id: UUID) throws -> Account {
        guard let a = accounts[id] else { throw LedgerError.accountNotFound(id) }
        return a
    }

    /// All accounts, ordered by name.
    public var all: [Account] {
        accounts.values.sorted { $0.name < $1.name }
    }

    /// Filters accounts by type.
    public func accounts(ofType type: AccountType) -> [Account] {
        all.filter { $0.type == type }
    }

    public var isEmpty: Bool { accounts.isEmpty }
    public var count: Int { accounts.count }
}
