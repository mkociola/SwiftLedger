/// Manages a `Ledger` and optional persistence.
public final class LedgerManager {
    private var ledger: Ledger
    private let store: (any LedgerStore)?

    public init(store: (any LedgerStore)? = nil) throws {
        self.store = store
        ledger = try store?.load() ?? Ledger()
    }

    // MARK: - Mutations

    /// Adds `item` and persists the result.
    ///
    /// Atomic: if the store's `save` throws, the in-memory ledger is
    /// left unchanged, so callers can safely retry.
    ///
    /// A transaction built in code is refused, with the balance error
    /// `Transaction.init` throws, when the journal would write it with more
    /// digits than it balances at: the file would not load back. See
    /// `balance(of:)`. A `.directive` holding `\n` is refused with
    /// `LedgerError.lineBreakInField("directive")`, for the reason the case
    /// itself gives, and any other directive line the next parse would
    /// refuse where it lands is refused with the parser's own error (issue
    /// #130).
    public func add(_ item: JournalItem) throws {
        var updated = ledger
        updated.add(item)
        try requireReloadable(item, formats: ledger.journal.commodityFormats)
        let reloaded = try Self.reloaded(updated, after: [item])
        try store?.save(updated)
        ledger = reloaded
    }

    /// Removes the first occurrence of `item` from the journal.
    ///
    /// Equality is value-based: if the journal contains two structurally
    /// identical items, only the first one is removed.
    ///
    /// Removing a directive line rereads the journal, as adding one does, so
    /// the entries below it are booked as the saved file books them, and a
    /// removal that would leave the file unreadable is refused with the
    /// parser's error (`reloaded(_:after:)`).
    ///
    /// - Returns: `true` if a matching item was found and removed;
    ///   `false` if no match exists.
    /// - Throws: Any error raised by the store's `save` method, or by the
    ///   parser for a directive line the file needs.
    @discardableResult
    public func remove(_ item: JournalItem) throws -> Bool {
        var updated = ledger
        guard updated.remove(item) else { return false }
        let reloaded = try Self.reloaded(updated, after: [item])
        try store?.save(updated)
        ledger = reloaded
        return true
    }

    /// Replaces the first occurrence of `item` with `replacement`, keeping its
    /// position in the file, and persists the result.
    ///
    /// One write, so an edit cannot half-apply: `remove` then `add` leaves the
    /// journal briefly without the entry, and a failed `add` has to be unwound
    /// by hand. Nothing to unwind here — either the save succeeds and the
    /// in-memory ledger advances with it, or neither happens.
    ///
    /// A replacement built in code is refused the way `add` refuses one, before
    /// anything is written. An original that is not in the journal is reported
    /// first: `false`, whatever the replacement is.
    ///
    /// - Returns: `true` if a matching item was found and replaced;
    ///   `false` if no match exists, in which case nothing was written.
    @discardableResult
    public func replace(_ item: JournalItem, with replacement: JournalItem) throws -> Bool {
        var updated = ledger
        guard updated.replace(item, with: replacement) else { return false }
        let file = ledger.journal.file(holding: item) ?? ledger.journal
        try requireReloadable(replacement, formats: file.commodityFormats)
        let reloaded = try Self.reloaded(updated, after: [item, replacement])
        try store?.save(updated)
        ledger = reloaded
        return true
    }

    /// Refuses an item the serializer would write as lines the next parse,
    /// or hledger, refuses, `formats` being the styles of the file it lands
    /// in: the top file for `add`, which puts every item there, and the file
    /// holding the original for `replace`.
    ///
    /// A transaction that still carries the lines it was parsed from is
    /// replayed verbatim and was checked when it was read, so it passes: that
    /// is what lets a removed entry be put back exactly as it was. One built
    /// in code is held to the digits that file writes it in, with the
    /// balance error `Transaction.init` throws.
    ///
    /// A `.directive` holding `\n` is refused for the reason
    /// `JournalItem.directive` gives (issue #72). Only `\n`, unlike
    /// `Transaction.requireOneLine`: the parser keeps a lone `\r` in a
    /// directive line, as hledger reads past one, so a directive read from the
    /// file has to go back in. Any other directive line is read where it
    /// lands, by the next parse itself: at the margin it may open with no
    /// word hledger knows or be a `D` or `decimal-mark` line hledger cannot
    /// read, indented it may belong to no block above it, and inside an open
    /// `comment` block it is text that reads back as it came. Only a parse of
    /// the journal as it would be saved knows all of that, so
    /// `reloaded(_:after:)` writes and reads `updated` once before the store
    /// sees it (issue #130).
    private func requireReloadable(_ item: JournalItem, formats: [String: CommodityFormat]) throws {
        switch item {
        case let .directive(text):
            if text.unicodeScalars.contains("\n") { throw LedgerError.lineBreakInField("directive") }
        case let .transaction(transaction) where transaction.sourceText == nil:
            try Transaction.requireBalanced(transaction.postings, formats: formats)
        default:
            break
        }
    }

    /// `ledger` as the next load reads it from the text it saves as, each
    /// entry under the id it has now, when one of `items` is a directive or
    /// an `include` line, and `ledger` itself otherwise.
    ///
    /// A directive line can change what every entry below it means: an
    /// `alias` or `apply account` line the account it is booked under, a `D`
    /// or `decimal-mark` line what its amounts are worth. Kept as it was, the
    /// ledger in memory went on reading those entries the old way while the
    /// saved file read them the new one, until `reload()` (issue #145). The
    /// parse keeps the entries in order and mints new ids, so the ids are
    /// carried over by position, and an entry the edit did not reach is still
    /// the value the caller holds. The parse also throws for a file that
    /// would not load, which is what refuses a directive line where it
    /// lands, and a removal that leaves the file unreadable, such as an
    /// `end apply account` whose opening line went.
    ///
    /// A journal read from a file is re-read from it, every file it includes
    /// with it, since a directive line above an `include` line changes what
    /// the included entries mean. Each file is served the text it is about to
    /// be saved as, and a file the journal does not hold yet, named by an
    /// `include` line just added, is read from disk. The ids are carried over
    /// file by file (`Journal.identified(like:)`), so adding or removing an
    /// `include` line leaves the entries of every other file under theirs.
    private static func reloaded(_ ledger: Ledger, after items: [JournalItem]) throws -> Ledger {
        let rereads = items.contains {
            switch $0 {
            case .directive, .include: true
            default: false
            }
        }
        guard rereads else { return ledger }
        let files = JournalSerializer().serializedFiles(ledger.journal)
        guard let top = ledger.journal.file else {
            return try Ledger(journal: JournalParser().parse(files[0].text).identified(like: ledger.journal))
        }
        let texts = Dictionary(
            files.compactMap { entry in entry.file.map { ($0.standardizedFileURL.path, entry.text) } },
            uniquingKeysWith: { first, _ in first },
        )
        let journal = try JournalParser().parse(fileAt: top) { file in
            try texts[file.path] ?? String(contentsOf: file, encoding: .utf8)
        }
        return Ledger(journal: journal.identified(like: ledger.journal))
    }

    /// Whether `postings` balance as this journal would write them: the answer
    /// `add` and `replace` give, without throwing.
    ///
    /// A number is padded to the digits the journal writes its commodity
    /// with, and an entry is held to the digits it is written in. So an entry
    /// that balances at `-1 USD` can be off once the file says `-1.00 USD`.
    public func balance(of postings: [Posting]) -> (real: BalanceVerdict, bracketed: BalanceVerdict) {
        Transaction.balance(of: postings, formats: ledger.journal.commodityFormats)
    }

    /// Removes the `account` directive declaring `name` and persists the result.
    ///
    /// Atomic in the same way as `remove(_:)`: nothing is written when no line
    /// declares `name`, and if the store's `save` throws the in-memory ledger is
    /// left unchanged, so callers can safely retry.
    ///
    /// - Returns: The directive removed — `type` and `comment` included, ready
    ///   to hand back to `add(_:)` as an undo step — or `nil` if `name` was not
    ///   declared. The indented lines under the directive go with it and are
    ///   not carried (`Journal.removeAccountDirective(named:)`).
    /// - Throws: Any error raised by the store's `save` method.
    @discardableResult
    public func removeAccountDirective(named name: String) throws -> AccountDirective? {
        var updated = ledger
        guard let removed = updated.removeAccountDirective(named: name) else { return nil }
        try store?.save(updated)
        ledger = updated
        return removed
    }

    // MARK: - Queries

    /// The journal as it currently stands: its items in document order, the
    /// unmodelled directive lines it preserves, and the display style its own
    /// text implies.
    ///
    /// Read-only. Every mutation goes through this type so that the file and
    /// the value in memory cannot disagree.
    public var currentJournal: Journal {
        ledger.journal
    }

    /// The `account` directive declaring `name`, or `nil` when the account is
    /// inferred from postings rather than declared.
    public func accountDirective(named name: String) -> AccountDirective? {
        ledger.accountDirective(named: name)
    }

    public func accounts() -> [Account] {
        ledger.accounts
    }

    public func balance(for accountName: String, asOf: JournalDate? = nil) -> [Amount] {
        ledger.balance(for: accountName, asOf: asOf)
    }

    public func subtreeBalance(forPrefix prefix: String, asOf: JournalDate? = nil) -> [Amount] {
        ledger.subtreeBalance(forPrefix: prefix, asOf: asOf)
    }

    public func subtreeBalanceSeries(
        forPrefix prefix: String,
        from: JournalDate,
        to: JournalDate, // swiftlint:disable:this identifier_name
    ) -> [[Amount]] {
        ledger.subtreeBalanceSeries(forPrefix: prefix, from: from, to: to)
    }

    public func incomeStatementSeries(
        bucketStarts: [JournalDate],
        to: JournalDate, // swiftlint:disable:this identifier_name
    ) -> [(revenues: [Amount], expenses: [Amount])] {
        ledger.incomeStatementSeries(bucketStarts: bucketStarts, to: to)
    }

    public func balanceMatrix(
        bucketStarts: [JournalDate],
        to: JournalDate, // swiftlint:disable:this identifier_name
        including: (@Sendable (Transaction) -> Bool)? = nil,
    ) -> BalanceMatrix {
        ledger.balanceMatrix(bucketStarts: bucketStarts, to: to, including: including)
    }

    public func transactions(for accountName: String) -> [Transaction] {
        ledger.transactions(for: accountName)
    }

    public func transactions(forPrefix prefix: String) -> [Transaction] {
        ledger.transactions(forPrefix: prefix)
    }

    // swiftlint:disable:next identifier_name
    public func transactions(from: JournalDate? = nil, to: JournalDate? = nil) -> [Transaction] {
        ledger.transactions(from: from, to: to)
    }

    public func balanceSheet(asOf: JournalDate? = nil) -> BalanceSheet {
        BalanceSheet(ledger: ledger, asOf: asOf)
    }

    // swiftlint:disable:next identifier_name
    public func incomeStatement(from: JournalDate? = nil, to: JournalDate? = nil) -> IncomeStatement {
        IncomeStatement(ledger: ledger, from: from, to: to)
    }

    public func accountStatement(
        for accountName: String,
        from: JournalDate? = nil,
        // swiftlint:disable:next identifier_name
        to: JournalDate? = nil,
    ) -> AccountStatement {
        AccountStatement(ledger: ledger, accountName: accountName, from: from, to: to)
    }

    /// Reloads from the store if one is present.
    public func reload() throws {
        guard let activeStore = store else { return }
        ledger = try activeStore.load()
    }
}
