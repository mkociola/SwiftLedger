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

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Cannot parse date: \(string)"
                )
            }
            return date
        }
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
