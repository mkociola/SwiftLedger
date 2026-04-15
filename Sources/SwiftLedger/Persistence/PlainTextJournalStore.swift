import Foundation

/// A `LedgerStore` backed by a plain-text `.ledger` file on disk.
///
/// Uses `JournalParser` to load and `JournalSerializer` to save, performing
/// an atomic write to protect against partial writes.
public final class PlainTextJournalStore: LedgerStore, @unchecked Sendable {
    private let url: URL
    private let parser     = JournalParser()
    private let serializer = JournalSerializer()

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Ledger {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let journal = try parser.parse(text)
            return Ledger(journal: journal)
        } catch let e as LedgerError {
            throw e
        } catch {
            throw LedgerError.storeError("Failed to read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func save(_ ledger: Ledger) throws {
        let text = serializer.serialize(ledger.journal)
        let data = Data(text.utf8)

        // Atomic write: write to a temp file then rename
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw LedgerError.storeError("Failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
