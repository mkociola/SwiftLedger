/// An `account` directive that appears in a journal file.
///
/// Declaring an account explicitly is optional in plain-text accounting;
/// accounts are also inferred from postings. Directives allow an explicit
/// account type to be specified.
public struct AccountDirective: Sendable, Codable, Hashable {
    public let name: String
    public let type: AccountType?
    /// Inline comment text following the account name (the part after `; `).
    public let comment: String?

    public init(name: String, type: AccountType? = nil, comment: String? = nil) {
        self.name = name
        self.type = type
        self.comment = comment
    }
}

/// A top-level item stored in an ordered journal AST.
///
/// Preserving all item types (including blank lines and comments) ensures
/// that serialisation round-trips do not alter the file's layout.
public enum JournalItem: Sendable, Codable, Hashable {
    case transaction(Transaction)
    case accountDirective(AccountDirective)
    case comment(String)
    /// A line SwiftLedger does not model: an unsupported directive such as
    /// `include`, `P`, `commodity`, `alias`, `D` or `year`, an indented
    /// sub-directive, or any other content outside the supported grammar.
    ///
    /// The payload is the source line **verbatim**, including its original
    /// indentation, and is written back byte-for-byte. Content SwiftLedger
    /// cannot interpret is never reinterpreted, commented out, or dropped.
    case directive(String)
    case blank
}

/// An ordered sequence of journal items forming a complete ledger file.
///
/// The `Journal` is an immutable value type representing the parse result of
/// one `.ledger` / `.journal` file. Use `Ledger` to perform queries over a
/// `Journal`.
public struct Journal: Sendable, Codable {
    public private(set) var items: [JournalItem]

    public init(items: [JournalItem] = []) {
        self.items = items
    }

    /// All transactions in document order.
    public var transactions: [Transaction] {
        items.compactMap {
            if case let .transaction(transaction) = $0 { return transaction }
            return nil
        }
    }

    /// All `account` directives in document order.
    public var accountDirectives: [AccountDirective] {
        items.compactMap {
            if case let .accountDirective(directive) = $0 { return directive }
            return nil
        }
    }

    /// The verbatim text of every unmodelled directive line, in document order.
    ///
    /// Use this to detect constructs SwiftLedger preserves but does not
    /// interpret — most notably `include`, whose referenced files are neither
    /// read nor written by `PlainTextJournalStore`.
    public var directives: [String] {
        items.compactMap {
            if case let .directive(text) = $0 { return text }
            return nil
        }
    }

    /// The `account` directive declaring `name`, or `nil` when no line declares
    /// it — an account inferred from postings alone has none.
    ///
    /// A directive's identity is the account name it declares; `type` and
    /// `comment` are data it carries. Look one up by name rather than
    /// reconstructing an equal value: a directive parsed from
    /// `account NAME  ; note` carries that comment, and a value built without
    /// it does not compare equal.
    public func accountDirective(named name: String) -> AccountDirective? {
        for case let .accountDirective(directive) in items where directive.name == name {
            return directive
        }
        return nil
    }

    /// Appends an item to the journal.
    public mutating func append(_ item: JournalItem) {
        items.append(item)
    }

    /// Removes the first occurrence of `item` from the journal.
    ///
    /// Equality is value-based: if the journal contains two structurally
    /// identical items, only the first one is removed.
    ///
    /// - Returns: `true` if a matching item was found and removed;
    ///   `false` if no match exists.
    @discardableResult
    public mutating func remove(_ item: JournalItem) -> Bool {
        guard let idx = items.firstIndex(of: item) else { return false }
        items.remove(at: idx)
        return true
    }

    /// Removes the `account` directive declaring `name` and returns it.
    ///
    /// Keyed by name, so the caller neither has to know the directive's `type`
    /// and `comment` to remove it, nor loses them by removing it: handed back
    /// to `append(_:)`, the returned value reproduces the line verbatim — at
    /// the end of the journal, as every append is, not at its old position.
    /// Removing by value through `remove(_:)` can do neither.
    ///
    /// If two lines declare the same account, only the first is removed.
    ///
    /// - Returns: The directive removed, or `nil` if nothing declared `name`.
    @discardableResult
    public mutating func removeAccountDirective(named name: String) -> AccountDirective? {
        for (index, item) in items.enumerated() {
            guard case let .accountDirective(directive) = item, directive.name == name else { continue }
            items.remove(at: index)
            return directive
        }
        return nil
    }
}
