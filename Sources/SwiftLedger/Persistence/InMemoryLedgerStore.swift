import Foundation

/// A `LedgerStore` that keeps the ledger in memory.
///
/// Useful for unit testing, previews, or in-process caches.
/// Data is **not** persisted between process launches.
public actor InMemoryLedgerStore: LedgerStore {
    private var ledger: Ledger

    public init(initial ledger: Ledger = Ledger()) {
        self.ledger = ledger
    }

    public func load() async throws -> Ledger {
        ledger
    }

    public func save(_ ledger: Ledger) async throws {
        self.ledger = ledger
    }
}
