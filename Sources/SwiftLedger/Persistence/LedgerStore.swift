/// Protocol for saving and loading a `Ledger`.
public protocol LedgerStore: Sendable {
    func load() throws -> Ledger
    func save(_ ledger: Ledger) throws
}
