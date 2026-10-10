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
    /// Every line of a block comment lands here too, the `comment` or `test`
    /// line that opens it and the `end comment` or `end test` line that closes
    /// it included (a whitespace-only line inside one is `.blank`).
    /// The block's contents are text the file tells the reader to skip, so a
    /// transaction written there arrives as directive lines rather than as a
    /// `.transaction`.
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

    /// How this file writes each commodity it mentions — decimal places,
    /// thousands separators and where a minus sign goes — as `JournalParser`
    /// found it.
    ///
    /// `JournalSerializer` writes a transaction it has to format in the style
    /// recorded here, so that editing one entry in a file of `$1,234.50` does
    /// not restyle that entry's amounts to `$1240.5` and put a change nobody
    /// asked for in the diff. A transaction nobody edited never reaches that
    /// code at all: it is replayed from its own source lines.
    ///
    /// Empty for a journal built in code, and for one decoded from JSON —
    /// this describes one file's layout rather than the events it records, so
    /// it is not encoded, exactly as `Transaction.sourceText` is not. A
    /// commodity that is missing here is written in
    /// `CommodityFormat.default(for:)`.
    public private(set) var commodityFormats: [String: CommodityFormat] = [:]

    /// How this file lines its posting amounts up, or `nil` when it showed no
    /// amount to learn from.
    ///
    /// Recorded for the same reason as `commodityFormats` and used the same
    /// way: a transaction the serializer has to format is laid out at the
    /// file's own margin rather than at the library's default of column 52, so
    /// an edit does not drag one entry's columns away from every other entry's.
    /// Not encoded, for the same reason again — it describes one file's layout.
    public private(set) var amountAlignment: AmountAlignment?

    /// The whitespace this file indents its postings with — two spaces, four,
    /// a tab — or `nil` when it showed none.
    ///
    /// Recorded and applied for the same reason as `amountColumn`: re-indenting
    /// the one entry the user edited is a change nobody asked for. Not encoded.
    public private(set) var postingIndent: String?

    public init(
        items: [JournalItem] = [],
        commodityFormats: [String: CommodityFormat] = [:],
        amountAlignment: AmountAlignment? = nil,
        postingIndent: String? = nil,
    ) {
        self.items = items
        self.commodityFormats = commodityFormats
        self.amountAlignment = amountAlignment
        self.postingIndent = postingIndent
    }

    /// The encoded shape of a journal. `commodityFormats`, `amountAlignment`
    /// and `postingIndent` are deliberately absent: they describe one file's
    /// layout rather than the events it records.
    private enum CodingKeys: String, CodingKey {
        case items
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

    /// Appends an item to the journal: at the end, unless the journal ends
    /// inside a block comment and the item is of a kind a block cannot hold.
    ///
    /// A `comment` or `test` block that nothing closes runs to the end of the
    /// file, so an entry written after its last line would be written into it.
    /// It would be counted until the next load and read as text from then on,
    /// with nothing thrown to say so. A transaction, an `account` directive or
    /// a comment goes in front of the line that opens the block instead, and
    /// the open block stays the last thing in the file.
    ///
    /// Only the item is inserted, with no blank line beside it, exactly as at
    /// the end of a journal. Removing it again therefore gives the file back
    /// byte for byte, which an undo step depends on.
    ///
    /// A `.directive` or a `.blank` goes at the end whatever the journal ends
    /// in. Those are the items a block is made of, so a journal copied or
    /// built one item at a time keeps its blocks where they were. The price is
    /// that such a line appended to a journal ending inside a block is part of
    /// the block from then on: a `D` or `P` line added there states nothing.
    public mutating func append(_ item: JournalItem) {
        switch item {
        case .transaction, .accountDirective, .comment:
            items.insert(item, at: openBlockCommentIndex ?? items.endIndex)
        case .directive, .blank:
            items.append(item)
        }
    }

    /// The index of the line opening the block comment this journal ends
    /// inside, or `nil` when it ends outside one.
    ///
    /// Read forward, the way `JournalParser` reads the file and with its own
    /// keyword rule, because a block cannot be told from its last lines: an
    /// opening keyword inside a block is one more line of it, so the last
    /// such line in the journal is not always where its block began.
    ///
    /// The reading starts after the last item that is neither a directive nor
    /// a blank, rather than at the top. The parser reads no other kind inside
    /// a block and `append` puts none there, so in a journal those two made,
    /// whatever follows the last such item starts outside a block. Reading
    /// from the top instead costs a pass over every item on every append,
    /// which an importer adding entries in a loop pays once per entry.
    ///
    /// `remove` and `replace` can undo that, by taking a closing line out or
    /// putting an opening one in front of an entry, and so can a hand-built
    /// list of items. The entry left behind the opening line is then already
    /// text on the next load, and one appended afterwards follows it there.
    private var openBlockCommentIndex: Int? {
        // ponytail: starts after the last non-block item, which trusts that
        // none sits inside an open block. Scan from index 0, or have the
        // parser record the open block, if `remove`/`replace` on a block's
        // keyword lines has to be survived.
        let lastOutside = items.lastIndex {
            switch $0 {
            case .transaction, .accountDirective, .comment: true
            case .directive, .blank: false
            }
        }
        let parser = JournalParser()
        var opening: Int?
        for index in (lastOutside.map { $0 + 1 } ?? items.startIndex) ..< items.endIndex {
            guard case let .directive(text) = items[index] else { continue }
            if opening == nil {
                if parser.isCommentBlockStart(text) { opening = index }
            } else if parser.isCommentBlockEnd(text) {
                opening = nil
            }
        }
        return opening
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

    /// Replaces the first occurrence of `item` with `replacement`, in place.
    ///
    /// The position is the point. Removing an item and appending its successor
    /// leaves the file reordered — the edited entry torn out of its date order
    /// and left at the end — which in a journal kept in version control is two
    /// changed hunks for a one-field edit, neither of them where the reader is
    /// looking. Equality is value-based, as it is for `remove(_:)`.
    ///
    /// - Returns: `true` if a matching item was found and replaced;
    ///   `false` if no match exists, in which case nothing changed.
    @discardableResult
    public mutating func replace(_ item: JournalItem, with replacement: JournalItem) -> Bool {
        guard let idx = items.firstIndex(of: item) else { return false }
        items[idx] = replacement
        return true
    }

    /// Removes the `account` directive declaring `name` and returns it.
    ///
    /// Keyed by name, so the caller neither has to know the directive's `type`
    /// and `comment` to remove it, nor loses them by removing it: handed back
    /// to `append(_:)`, the returned value reproduces the line verbatim, where
    /// an appended `account` directive lands (the end of the journal, or in front of a
    /// block comment left open there) and not at its old position.
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
