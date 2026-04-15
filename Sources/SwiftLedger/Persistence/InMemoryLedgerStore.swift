/// A non-persistent in-memory store — primarily for testing.
public final class InMemoryLedgerStore: LedgerStore {
    private var ledger: Ledger

    public init(ledger: Ledger = Ledger()) {
        self.ledger = ledger
    }

    public func load() throws -> Ledger { ledger }
    public func save(_ ledger: Ledger) throws { self.ledger = ledger }
}
