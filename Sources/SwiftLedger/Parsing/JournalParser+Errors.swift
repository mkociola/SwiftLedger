// MARK: - Saying where in the file an error was found

import Foundation

extension JournalParser {
    /// Runs `work` and gives whatever it throws the place in the file it came
    /// from.
    ///
    /// Every error a journal refuses to load with passes through here, so what
    /// a located error is made of is decided once: the line to open the file
    /// at, the header of the entry the problem sits in, and the error itself
    /// underneath, untouched, for a caller that matches on the cause.
    ///
    /// Two errors are handed back bare. `parseError` carries a line of its own
    /// and would otherwise print one twice. An error that arrives already
    /// located was found further in, on a line of its own — a posting's amount
    /// is written on the posting's line, not on the header's — and the
    /// narrower line is the one worth keeping.
    func located<T>(line: Int, entry: String, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as LedgerError {
            switch error {
            case .parseError, .inJournal:
                throw error
            default:
                throw LedgerError.inJournal(line: line, entry: entry, underlying: error)
            }
        }
    }

    /// The header line as an error names the entry it belongs to: what the
    /// file says, with the line ending and any trailing spaces taken off.
    ///
    /// Nothing else is changed. Someone searching their journal for the entry
    /// an error names has to find it spelled the way they wrote it, and the
    /// `\r` of a Windows ending is not a character anybody can type into a
    /// search field.
    static func entryHeader(_ line: String) -> String {
        var header = line
        while let last = header.last, last.isWhitespace { header.removeLast() }
        return header
    }
}
