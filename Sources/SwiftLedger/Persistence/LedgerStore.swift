import Foundation

/// A protocol for loading and saving a ``Ledger``.
///
/// Conform to this protocol in your app to provide SwiftData, CoreData,
/// or file-based persistence, while keeping the core library storage-agnostic.
///
/// Example:
/// ```swift
/// actor MySwiftDataStore: LedgerStore {
///     func load() async throws -> Ledger { ... }
///     func save(_ ledger: Ledger) async throws { ... }
/// }
/// ```
public protocol LedgerStore: Sendable {
    /// Loads the persisted ledger, or returns an empty one if none exists.
    func load() async throws -> Ledger
    /// Persists the current state of the ledger.
    func save(_ ledger: Ledger) async throws
}
