import Foundation

/// A `LedgerStore` backed by a plain-text `.ledger` file on disk.
///
/// Uses `JournalParser.parse(fileAt:)` to load, following the file's
/// `include` lines, and `JournalSerializer` to save, writing each file to a
/// temporary file first and moving it into place, to protect against partial
/// writes.
///
/// An edit to an entry of an included file is saved to that file. An included
/// file is written only when it was edited here (`Journal.edited`) and its
/// text differs from what the store last read from it or wrote to it, so a
/// file nobody edited keeps its bytes and its modification date, even one the
/// serializer would write back differently. The top file is always written,
/// to `url`.
///
/// No file the store has read is written over a change made to it since. When
/// a file about to be written has changed on disk since the store last read or
/// wrote it, or cannot be read any more, the save is refused and nothing is
/// written, so an edit made in another app or on another device is never
/// replaced by an older copy held in memory. A file the store never read (one
/// named by an `include` line added after the load) has nothing to compare
/// against and is written as before.
public final class PlainTextJournalStore: LedgerStore {
    private let url: URL
    private let parser = JournalParser()
    private let serializer = JournalSerializer()
    /// The text last read from or written to each file, by its standardised
    /// path.
    private var snapshots: [String: String] = [:]

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Ledger {
        do {
            var read: [String: String] = [:]
            let journal = try parser.parse(fileAt: url) { file in
                let text = try String(contentsOf: file, encoding: .utf8)
                read[file.standardizedFileURL.path] = text
                return text
            }
            snapshots = read
            return Ledger(journal: journal)
        } catch let ledgerError as LedgerError {
            throw ledgerError
        } catch {
            throw LedgerError.storeError("Failed to read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Writes every file of `ledger` that `filesToWrite` selects, refusing a
    /// file whose text on disk no longer matches its snapshot.
    ///
    /// - Throws: `LedgerError.storeError` naming the file, with nothing written.
    public func save(_ ledger: Ledger) throws {
        let files = try filesToWrite(ledger.journal)
        for (file, _) in files {
            guard let snapshot = snapshots[file.path] else { continue }
            // Compared byte for byte: `String ==` treats two Unicode
            // normalisations of one text as equal, and writing memory over
            // the other normalisation would still rewrite the file.
            let onDisk = try? String(contentsOf: file, encoding: .utf8)
            guard let onDisk, onDisk.utf8.elementsEqual(snapshot.utf8) else {
                throw LedgerError.storeError(
                    "\(file.lastPathComponent) has changed on disk since it was last read, so nothing was written. "
                        + "Try again once that change has been loaded.",
                )
            }
        }
        var staged: [(file: URL, tmp: URL)] = []
        var current = url
        do {
            for (file, text) in files {
                current = file
                let tmp = Self.stagingURL(for: file)
                staged.append((file, tmp))
                try Data(text.utf8).write(to: tmp, options: .atomic)
            }
            // ponytail: each move is atomic, the set of them is not; a crash
            // between two leaves one file new and one old. A journal-level
            // transaction log if that ever matters.
            for (file, tmp) in staged {
                current = file
                _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            }
        } catch {
            for (_, tmp) in staged {
                try? FileManager.default.removeItem(at: tmp)
            }
            throw LedgerError.storeError("Failed to write \(current.lastPathComponent): \(error.localizedDescription)")
        }
        for (file, text) in files {
            snapshots[file.standardizedFileURL.path] = text
        }
    }

    /// Where `save` writes `file`'s new text before moving it into place: a
    /// hidden file beside it.
    ///
    /// A crash between the write and the move leaves this file behind, and
    /// an `include 2024/*` line would read `jan.journal.tmp` as one more
    /// journal, every entry in it counted twice. A glob passes over a name
    /// that starts with a dot, in hledger and here, so the leftover is never
    /// read.
    static func stagingURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).tmp")
    }

    /// The files `save` writes, with their text: the top file, to `url`,
    /// then every included file edited here whose text differs from its
    /// snapshot.
    ///
    /// - Throws: `LedgerError.storeError` when one file is included twice and
    ///   its two copies would be written differently, so an edit made in one
    ///   copy would be lost or would overwrite the other. Nothing is written.
    private func filesToWrite(_ journal: Journal) throws -> [(file: URL, text: String)] {
        var files = serializer.serializedFiles(journal)
        files[0].file = url
        var written: [String: String] = [:]
        var result: [(file: URL, text: String)] = []
        for (index, entry) in files.enumerated() {
            guard let file = entry.file?.standardizedFileURL else { continue }
            if let earlier = written[file.path] {
                guard earlier == entry.text else {
                    throw LedgerError.storeError(
                        "\(file.lastPathComponent) is included more than once and was edited in one place only",
                    )
                }
                continue
            }
            written[file.path] = entry.text
            if index == 0 || entry.edited && snapshots[file.path] != entry.text { result.append((file, entry.text)) }
        }
        return result
    }
}
