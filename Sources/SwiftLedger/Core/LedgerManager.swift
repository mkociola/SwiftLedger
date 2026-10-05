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
    /// `balance(of:)`.
    public func add(_ item: JournalItem) throws {
        try requireReloadable(item)
        var updated = ledger
        updated.add(item)
        try store?.save(updated)
        ledger = updated
    }

    /// Removes the first occurrence of `item` from the journal.
    ///
    /// Equality is value-based: if the journal contains two structurally
    /// identical items, only the first one is removed.
    ///
    /// - Returns: `true` if a matching item was found and removed;
    ///   `false` if no match exists.
    /// - Throws: Any error raised by the store's `save` method.
    @discardableResult
    public func remove(_ item: JournalItem) throws -> Bool {
        var updated = ledger
        guard updated.remove(item) else { return false }
        try store?.save(updated)
        ledger = updated
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
        try requireReloadable(replacement)
        try store?.save(updated)
        ledger = updated
        return true
    }

    /// Refuses a transaction the serializer would write as lines the next
    /// parse, or hledger, refuses.
    ///
    /// A transaction that still carries the lines it was parsed from is
    /// replayed verbatim and was checked when it was read, so it passes: that
    /// is what lets a removed entry be put back exactly as it was.
    private func requireReloadable(_ item: JournalItem) throws {
        guard case let .transaction(transaction) = item, transaction.sourceText == nil else { return }
        try Transaction.requireBalanced(transaction.postings, formats: ledger.journal.commodityFormats)
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
    ///   declared.
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
