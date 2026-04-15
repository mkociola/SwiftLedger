import Foundation

/// A thread-safe actor that wraps ``Ledger`` for use in concurrent contexts.
///
/// `LedgerManager` serialises all mutations and queries through Swift's actor
/// isolation, so you can safely share one instance across the app without
/// additional locking. Optionally supply a ``LedgerStore`` for persistence.
///
/// ```swift
/// let store = FileLedgerStore(url: ledgerFileURL)
/// let manager = LedgerManager(store: store)
/// try await manager.load()          // hydrate from disk
/// try await manager.addAccount(…)
/// try await manager.post(tx)
/// try await manager.save()          // flush to disk
/// ```
public actor LedgerManager {
    private var ledger: Ledger
    private let store: (any LedgerStore)?

    public init(ledger: Ledger = Ledger(), store: (any LedgerStore)? = nil) {
        self.ledger = ledger
        self.store = store
    }

    // MARK: - Persistence

    /// Loads the ledger from the store, replacing any in-memory state.
    /// Does nothing if no store was provided.
    public func load() async throws {
        guard let store else { return }
        ledger = try await store.load()
    }

    /// Persists the current ledger to the store.
    /// Does nothing if no store was provided.
    public func save() async throws {
        guard let store else { return }
        try await store.save(ledger)
    }

    // MARK: - Account management

    public func addAccount(_ account: Account) throws {
        try ledger.addAccount(account)
    }

    public func removeAccount(id: UUID) throws {
        try ledger.removeAccount(id: id)
    }

    // MARK: - Posting

    public func post(_ transaction: Transaction) throws {
        try ledger.post(transaction)
    }

    /// Posts a reversing transaction for `transaction`.
    /// - Throws: `LedgerError.transactionNotFound` if the transaction was not posted to this ledger.
    public func reverse(
        _ transaction: Transaction,
        memo: String? = nil,
        date: Date = Date()
    ) throws {
        try ledger.reverse(transaction, memo: memo, date: date)
    }

    // MARK: - Balance queries

    public func balance(for accountID: UUID) throws -> AccountBalance {
        try ledger.balance(for: accountID)
    }

    public func balance(for accountID: UUID, asOf date: Date) throws -> AccountBalance {
        try ledger.balance(for: accountID, asOf: date)
    }

    public func subtreeBalances(forPrefix prefix: String) -> [AccountBalance] {
        ledger.subtreeBalances(forPrefix: prefix)
    }

    public func subtreeBalances(forPrefix prefix: String, asOf date: Date) -> [AccountBalance] {
        ledger.subtreeBalances(forPrefix: prefix, asOf: date)
    }

    public func allBalances() -> [AccountBalance] {
        ledger.allBalances()
    }

    public func trialBalance() -> TrialBalance {
        ledger.trialBalance()
    }

    // MARK: - Transaction history

    public func transactions(
        for accountID: UUID,
        from start: Date? = nil,
        to end: Date? = nil
    ) throws -> [Transaction] {
        try ledger.transactions(for: accountID, from: start, to: end)
    }

    public func transactions(forPrefix prefix: String) -> [Transaction] {
        ledger.transactions(forPrefix: prefix)
    }

    // MARK: - Read-only access to the underlying chart of accounts

    public var chartOfAccounts: ChartOfAccounts {
        ledger.chartOfAccounts
    }
}
