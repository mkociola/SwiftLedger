/// Protocol for saving and loading a `Ledger`.
public protocol LedgerStore {
    func load() throws -> Ledger
    func save(_ ledger: Ledger) throws
}
