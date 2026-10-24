import Foundation

/// The files an `include` line names, as `JournalParser.parse(fileAt:)` read
/// them.
///
/// `line` is the line as the file writes it, so that serialising gives it back
/// byte for byte. `journals` holds one `Journal` per file the line matched, in
/// the order hledger reads them (a glob's matches sorted by path), each one
/// file with its own layout and its own `file`, so an edit in one of them is
/// written back to that file and to no other.
public struct IncludedFiles: Sendable, Codable, Hashable {
    public let line: String
    public internal(set) var journals: [Journal]

    public init(line: String, journals: [Journal]) {
        self.line = line
        self.journals = journals
    }
}

public extension Journal {
    /// All transactions in document order, those of an included file at the
    /// `include` line that reads it.
    ///
    /// hledger reads an included file where the line stands, so a balance
    /// assertion after the line counts the included entries and one before it
    /// does not. Reading the tree in that order is what lets `Ledger` and every
    /// report see a journal of many files as the one journal hledger sees.
    var transactions: [Transaction] {
        items.flatMap { item -> [Transaction] in
            switch item {
            case let .transaction(transaction): [transaction]
            case let .include(included): included.journals.flatMap(\.transactions)
            default: []
            }
        }
    }

    /// All `account` directives in document order, those of an included file
    /// at its `include` line, for the reason `transactions` reads them so.
    var accountDirectives: [AccountDirective] {
        items.flatMap { item -> [AccountDirective] in
            switch item {
            case let .accountDirective(directive): [directive]
            case let .include(included): included.journals.flatMap(\.accountDirectives)
            default: []
            }
        }
    }

    /// The verbatim text of every unmodelled directive line in this file, in
    /// document order, an `include` line included whether it was followed or
    /// not.
    ///
    /// Use this to detect constructs SwiftLedger preserves but does not
    /// interpret. Only this file's own lines are listed, not those of the
    /// files it includes: the list describes the file in hand. A line holding
    /// nothing but spaces or tabs is listed too, since it is kept the same way.
    var directives: [String] {
        items.compactMap {
            switch $0 {
            case let .directive(text): text
            case let .include(included): included.line
            default: nil
            }
        }
    }

    /// The `account` directive declaring `name`, in this file or in one it
    /// includes, or `nil` when no line declares it: an account inferred from
    /// postings alone has none.
    ///
    /// A directive's identity is the account name it declares; `type` and
    /// `comment` are data it carries. Look one up by name rather than
    /// reconstructing an equal value: a directive parsed from
    /// `account NAME  ; note` carries that comment, and a value built without
    /// it does not compare equal.
    func accountDirective(named name: String) -> AccountDirective? {
        accountDirectives.first { $0.name == name }
    }
}

extension Journal {
    /// This journal, then every journal it includes, depth first in document
    /// order: one value per file read, a file included twice listed twice.
    var files: [Journal] {
        [self] + items.flatMap { item -> [Journal] in
            guard case let .include(included) = item else { return [] }
            return included.journals.flatMap(\.files)
        }
    }
}
