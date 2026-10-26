// MARK: - Finishing a parse once every file is read

import Foundation

extension JournalParser {
    /// An entry the parse could not finish where it stood: one of its postings
    /// is a balance assignment, an assertion with no amount in front of it,
    /// whose amount depends on entries the parse has not reached yet.
    struct RawEntry {
        var header: ParsedHeader
        var rawPostings: [RawPosting]
        var leadingComments: [String]
        /// The lines the entry was read from, for `Transaction.sourceText`.
        var source: String
        /// The header's 1-based line, for an error found while finishing it.
        var lineNumber: Int
    }

    /// What `parse(_:in:)` makes of one line or block: a finished item, an
    /// entry still to finish, or an `include` line with the files it read.
    enum ParsedItem {
        case item(JournalItem)
        case entry(RawEntry)
        case include(line: String, lineNumber: Int, files: [ParsedFile])
    }

    /// One file as `parse(_:in:)` read it, before `finish(_:)` turns it and
    /// the files it includes into a `Journal`.
    struct ParsedFile {
        var items: [ParsedItem]
        var style: JournalStyleCollector
        var lineEnding: LineEnding
        var file: URL?
    }

    /// The journal of `file` and the files it includes.
    func finish(_ file: ParsedFile) throws -> Journal {
        let resolved: [Transaction] = []
        var next = 0
        return journal(of: file, taking: resolved, next: &next)
    }

    /// `file` as a `Journal`, each raw entry replaced by its transaction in
    /// `resolved`, which holds them in document order.
    private func journal(of file: ParsedFile, taking resolved: [Transaction], next: inout Int) -> Journal {
        var items: [JournalItem] = []
        for item in file.items {
            switch item {
            case let .item(item):
                items.append(item)
            case .entry:
                items.append(.transaction(resolved[next]))
                next += 1
            case let .include(line, _, files):
                let journals = files.map { journal(of: $0, taking: resolved, next: &next) }
                items.append(.include(IncludedFiles(line: line, journals: journals)))
            }
        }
        return Journal(items: items, style: file.style, lineEnding: file.lineEnding, file: file.file)
    }
}
