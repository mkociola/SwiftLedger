/// An `account` directive that appears in a journal file.
///
/// Declaring an account explicitly is optional in plain-text accounting;
/// accounts are also inferred from postings. Directives allow an explicit
/// account type to be specified.
public struct AccountDirective: Sendable, Codable, Hashable {
    public let name: String
    public let type: AccountType?

    public init(name: String, type: AccountType? = nil) {
        self.name = name
        self.type = type
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
            if case .transaction(let transaction) = $0 { return transaction }
            return nil
        }
    }

    /// All `account` directives in document order.
    public var accountDirectives: [AccountDirective] {
        items.compactMap {
            if case .accountDirective(let directive) = $0 { return directive }
            return nil
        }
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
}
