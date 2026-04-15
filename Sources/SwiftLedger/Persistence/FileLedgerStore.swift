import Foundation

/// A `LedgerStore` that persists the ledger as a JSON file at a given URL.
///
/// Data survives process restarts. Writes are atomic (written to a temp file
/// then renamed), preventing partial writes from corrupting stored data.
///
/// ```swift
/// let store = FileLedgerStore(url: .documentsDirectory.appending(path: "ledger.json"))
/// let manager = LedgerManager(store: store)
/// try await manager.load()
/// ```
public actor FileLedgerStore: LedgerStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func load() async throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Ledger()
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Ledger.self, from: data)
    }

    public func save(_ ledger: Ledger) async throws {
        let data = try encoder.encode(ledger)
        try data.write(to: url, options: .atomic)
    }
}
