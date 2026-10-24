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

extension Journal {
    /// Applies `edit` to each journal this one includes, in document order,
    /// until one answers, and keeps the edited journal where it was.
    ///
    /// `remove`, `replace` and `removeAccountDirective(named:)` look in this
    /// file's own items before calling this, and `edit` is one of them, so
    /// each included file is searched the same way in turn. The top file
    /// first means that undoing an `add` removes the line just added, even
    /// when an included file holds an equal one.
    mutating func editIncluded<Answer>(_ edit: (inout Journal) -> Answer?) -> Answer? {
        for index in items.indices {
            guard case var .include(included) = items[index] else { continue }
            for child in included.journals.indices {
                guard let answer = edit(&included.journals[child]) else { continue }
                items[index] = .include(included)
                return answer
            }
        }
        return nil
    }
}

extension Journal {
    /// The journal of the file holding `item`, searched in the order
    /// `replace(_:with:)` searches, or `nil` when no file holds it.
    func file(holding item: JournalItem) -> Journal? {
        if items.contains(item) { return self }
        for case let .include(included) in items {
            for child in included.journals {
                if let found = child.file(holding: item) { return found }
            }
        }
        return nil
    }

    /// This journal, re-read, with each file's entries under the ids `old`
    /// gave the same file's entries, in order.
    ///
    /// A parse mints new ids, and the caller holds values carrying the old
    /// ones. The top file takes the top file's ids and an included file those
    /// of the file at the same path, a file included twice taking its copies'
    /// ids in turn, so an `include` line added or removed shifts no other
    /// file's entries. An entry with no id left to take keeps the new one.
    func identified(like old: Journal) -> Journal {
        var ids: [String?: ArraySlice<UUID>] = [:]
        for (index, file) in old.files.enumerated() {
            let own = file.items.compactMap { if case let .transaction(entry) = $0 { entry.id } else { nil } }
            ids[index == 0 ? nil : file.file?.path, default: []] += own
        }
        return identified(isTop: true, taking: &ids)
    }

    private func identified(isTop: Bool, taking ids: inout [String?: ArraySlice<UUID>]) -> Journal {
        var copy = self
        let key = isTop ? nil : file?.path
        for index in items.indices {
            switch items[index] {
            case let .transaction(entry):
                guard isTop || file != nil, let id = ids[key]?.popFirst() else { continue }
                copy.items[index] = .transaction(entry.identified(as: id))
            case var .include(included):
                for child in included.journals.indices {
                    included.journals[child] = included.journals[child].identified(isTop: false, taking: &ids)
                }
                copy.items[index] = .include(included)
            default:
                continue
            }
        }
        return copy
    }
}

/// Whether a file was edited since it was read (`Journal.edited`), kept out
/// of the journal's value: two journals holding the same items are equal
/// however they came to hold them, so every mark compares equal.
struct EditMark: Hashable {
    var isSet = false

    static func == (_: EditMark, _: EditMark) -> Bool {
        true
    }

    func hash(into _: inout Hasher) {}
}
