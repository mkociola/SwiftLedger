import Foundation

/// The plain-text accounting query engine.
///
/// `Ledger` wraps a `Journal` and provides balance queries, account
/// enumeration, and transaction filtering. Accounts are inferred automatically
/// from posting names — no pre-registration is required.
public struct Ledger: Sendable {
    public private(set) var journal: Journal

    public init(journal: Journal = Journal()) {
        self.journal = journal
    }

    // MARK: - Mutation

    /// Appends an item to the journal.
    public mutating func add(_ item: JournalItem) {
        journal.append(item)
    }

    /// Removes the first occurrence of `item` from the journal.
    ///
    /// - Returns: `true` if a matching item was found and removed;
    ///   `false` if no match exists.
    @discardableResult
    public mutating func remove(_ item: JournalItem) -> Bool {
        journal.remove(item)
    }

    /// Replaces the first occurrence of `item` with `replacement`, keeping its
    /// position in the file.
    ///
    /// - Returns: `true` if a matching item was found and replaced;
    ///   `false` if no match exists.
    @discardableResult
    public mutating func replace(_ item: JournalItem, with replacement: JournalItem) -> Bool {
        journal.replace(item, with: replacement)
    }

    /// Removes the `account` directive declaring `name` and returns it, with
    /// its `type` and `comment` intact.
    ///
    /// - Returns: The directive removed, or `nil` if nothing declared `name`.
    @discardableResult
    public mutating func removeAccountDirective(named name: String) -> AccountDirective? {
        journal.removeAccountDirective(named: name)
    }

    // MARK: - Accounts

    /// The `account` directive declaring `name`, or `nil` when the account is
    /// inferred from postings rather than declared.
    public func accountDirective(named name: String) -> AccountDirective? {
        journal.accountDirective(named: name)
    }

    /// All accounts inferred from posting names, merged with any explicit
    /// `account` directives. Sorted by name.
    public var accounts: [Account] {
        var seen: [String: Account] = [:]

        // Explicit directives take precedence for type metadata.
        for directive in journal.accountDirectives {
            let account = Account(name: directive.name, type: directive.type)
            seen[directive.name] = account
        }

        // Infer from postings.
        for transaction in journal.transactions {
            for posting in transaction.postings where seen[posting.accountName] == nil {
                seen[posting.accountName] = Account(name: posting.accountName)
            }
        }

        // Also infer all parent segments.
        for name in Array(seen.keys) {
            var parts = name.split(separator: ":")
            while parts.count > 1 {
                parts.removeLast()
                let parentName = parts.joined(separator: ":")
                if seen[parentName] == nil {
                    seen[parentName] = Account(name: parentName)
                }
            }
        }

        return seen.values.sorted { $0.name < $1.name }
    }

    // MARK: - Balance queries

    /// Returns the net balance for an exact account name, grouped by commodity.
    /// An optional `asOf` date filters to transactions on or before that date.
    public func balance(for accountName: String, asOf: JournalDate? = nil) -> [Amount] {
        postings(for: accountName, asOf: asOf)
            .map(\.amount)
            .netByCommodity()
    }

    /// Returns the net balance for an account and all of its sub-accounts,
    /// grouped by commodity.
    public func subtreeBalance(forPrefix prefix: String, asOf: JournalDate? = nil) -> [Amount] {
        postingsInSubtree(prefix: prefix, asOf: asOf)
            .map(\.amount)
            .netByCommodity()
    }

    /// Returns daily closing subtree balances for `prefix`, one entry per
    /// Gregorian day from `from` through `to` inclusive.
    ///
    /// Each entry matches what `subtreeBalance(forPrefix:asOf:)` returns for
    /// that day (netted by commodity, zeros included, sorted by commodity),
    /// but the whole series is computed in one pass over the journal instead
    /// of one full scan per day. Returns `[]` when `from > to`.
    public func subtreeBalanceSeries(
        forPrefix prefix: String,
        from: JournalDate,
        to: JournalDate, // swiftlint:disable:this identifier_name
    ) -> [[Amount]] {
        guard from <= to else { return [] }

        // Running balance per commodity; seeded with everything before the
        // window, then advanced day by day through the window itself.
        var running: CommoditySums = [:]
        func fold(_ transaction: Transaction) {
            for posting in transaction.postings {
                guard isInSubtree(posting.accountName, prefix: prefix) else { continue }
                Self.accumulate(posting.amount, into: &running)
            }
        }

        var window: [Transaction] = []
        for transaction in journal.transactions where transaction.date <= to {
            if transaction.date < from {
                fold(transaction)
            } else {
                window.append(transaction)
            }
        }
        window.sort { $0.date < $1.date }

        let calendar = Calendar(identifier: .gregorian)
        let fromDate = from.date()
        let dayCount =
            (calendar.dateComponents([.day], from: fromDate, to: to.date()).day ?? 0) + 1

        var series: [[Amount]] = []
        series.reserveCapacity(dayCount)
        var index = window.startIndex
        for offset in 0 ..< dayCount {
            let day = JournalDate(calendar.date(byAdding: .day, value: offset, to: fromDate)!)
            while index < window.endIndex, window[index].date <= day {
                fold(window[index])
                index = window.index(after: index)
            }
            series.append(Self.amounts(from: running))
        }
        return series
    }

    /// Returns per-bucket revenue and expense totals over consecutive date
    /// buckets, netted by commodity with zero-net entries dropped.
    ///
    /// `bucketStarts` are ascending bucket start dates: bucket `i` covers
    /// `bucketStarts[i]` through the day before `bucketStarts[i + 1]`, and
    /// the last bucket runs through `to`. Totals match what building an
    /// `IncomeStatement` per bucket produces (explicit account directives
    /// override name-based type inference), in one pass over the journal.
    public func incomeStatementSeries(
        bucketStarts: [JournalDate],
        to: JournalDate, // swiftlint:disable:this identifier_name
    ) -> [(revenues: [Amount], expenses: [Amount])] {
        guard let firstStart = bucketStarts.first else { return [] }

        let declaredTypes = directiveTypes
        var revenueSums = [CommoditySums](repeating: [:], count: bucketStarts.count)
        var expenseSums = revenueSums
        for transaction in journal.transactions {
            guard transaction.date >= firstStart, transaction.date <= to else { continue }
            guard let bucket = Self.bucketIndex(for: transaction.date, in: bucketStarts)
            else { continue }
            for posting in transaction.postings {
                let type =
                    declaredTypes[posting.accountName]
                        ?? AccountType.inferred(from: posting.accountName)
                guard type == .revenue || type == .expense else { continue }
                if type == .revenue {
                    Self.accumulate(posting.amount, into: &revenueSums[bucket])
                } else {
                    Self.accumulate(posting.amount, into: &expenseSums[bucket])
                }
            }
        }

        return zip(revenueSums, expenseSums).map { revenues, expenses in
            (
                revenues: Self.amounts(from: revenues, dropZeros: true),
                expenses: Self.amounts(from: expenses, dropZeros: true),
            )
        }
    }

    /// Explicit `account` directive types keyed by account name, for the
    /// queries that type accounts the way `accounts` does: directive first,
    /// name inference second. Directives declaring no type are omitted, so a
    /// lookup miss means "infer from the name".
    var directiveTypes: [String: AccountType] {
        var types: [String: AccountType] = [:]
        for directive in journal.accountDirectives {
            if let type = directive.type { types[directive.name] = type }
        }
        return types
    }

    /// The index of the bucket `date` falls in — the last start on or before
    /// it — or `nil` when `date` precedes every start.
    ///
    /// `bucketStarts` must be ascending: that is the bucketing contract
    /// `incomeStatementSeries(bucketStarts:to:)` and
    /// `balanceMatrix(bucketStarts:to:including:)` share, and this is the one
    /// place that implements it. Bucket counts are small (report columns), so
    /// a linear scan is fine.
    static func bucketIndex(for date: JournalDate, in bucketStarts: [JournalDate]) -> Int? {
        bucketStarts.lastIndex(where: { $0 <= date })
    }

    /// Running per-commodity sums; the Bool is the commodity's display-prefix
    /// flag, carried through like `netByCommodity()`.
    ///
    /// Internal rather than private: `balanceMatrix(bucketStarts:to:including:)`
    /// folds postings the same way from `Reports/BalanceMatrix.swift`.
    typealias CommoditySums = [String: (quantity: Decimal, isPrefix: Bool)]

    /// Adds `amount` into the running per-commodity sums.
    static func accumulate(_ amount: Amount, into sums: inout CommoditySums) {
        let current = sums[amount.commodity, default: (.zero, amount.commodityIsPrefix)]
        sums[amount.commodity] = (current.quantity + amount.quantity, amount.commodityIsPrefix)
    }

    /// Converts running per-commodity sums into `Amount`s sorted by commodity.
    static func amounts(from sums: CommoditySums, dropZeros: Bool = false) -> [Amount] {
        sums
            .map {
                Amount(
                    quantity: $0.value.quantity,
                    commodity: $0.key,
                    commodityIsPrefix: $0.value.isPrefix,
                )
            }
            .filter { !dropZeros || !$0.isZero }
            .sorted { $0.commodity < $1.commodity }
    }

    /// Returns all account balances as a dictionary keyed by account name.
    /// Each value is a list of `Amount` (one per commodity).
    public func allBalances(asOf: JournalDate? = nil) -> [String: [Amount]] {
        var result: [String: [Amount]] = [:]
        for account in accounts {
            let bal = balance(for: account.name, asOf: asOf)
            if !bal.isEmpty {
                result[account.name] = bal
            }
        }
        return result
    }

    // MARK: - Transaction queries

    /// Returns transactions that contain at least one posting for an exact
    /// account name, sorted by date then by original document order.
    public func transactions(for accountName: String) -> [Transaction] {
        filteredTransactions { transaction in
            transaction.postings.contains { $0.accountName == accountName }
        }
    }

    /// Returns transactions that contain at least one posting in the account
    /// subtree rooted at `prefix`, sorted by date then by original document
    /// order.
    public func transactions(forPrefix prefix: String) -> [Transaction] {
        filteredTransactions { transaction in
            transaction.postings.contains { isInSubtree($0.accountName, prefix: prefix) }
        }
    }

    /// Returns all transactions within an optional date range (inclusive),
    /// sorted by date then by original document order.
    public func transactions(
        from: JournalDate? = nil, to: JournalDate? = nil, // swiftlint:disable:this identifier_name
    ) -> [Transaction] {
        filteredTransactions { transaction in
            if let from, transaction.date < from { return false }
            if let toDate = to, transaction.date > toDate { return false }
            return true
        }
    }

    // MARK: - Private helpers

    /// Filters the journal's transactions into date order, breaking ties by
    /// original document position.
    ///
    /// A journal's items are stored in document order, which is not
    /// necessarily chronological: `add(_:)` appends, so a back-dated entry
    /// lands after entries it precedes. Sorting here is what lets every
    /// transaction query — and the running balance `AccountStatement` builds
    /// on top of them — read chronologically. `sorted(by:)` is not guaranteed
    /// stable, so the document index is carried through the comparison rather
    /// than assumed to survive it.
    private func filteredTransactions(_ predicate: (Transaction) -> Bool) -> [Transaction] {
        journal.transactions
            .enumerated()
            .filter { predicate($0.element) }
            .sorted { lhs, rhs in
                lhs.element.date == rhs.element.date
                    ? lhs.offset < rhs.offset
                    : lhs.element.date < rhs.element.date
            }
            .map(\.element)
    }

    private func postings(for accountName: String, asOf: JournalDate?) -> [Posting] {
        journal.transactions
            .filter { transaction in asOf.map { transaction.date <= $0 } ?? true }
            .flatMap(\.postings)
            .filter { $0.accountName == accountName }
    }

    private func postingsInSubtree(prefix: String, asOf: JournalDate?) -> [Posting] {
        journal.transactions
            .filter { transaction in asOf.map { transaction.date <= $0 } ?? true }
            .flatMap(\.postings)
            .filter { isInSubtree($0.accountName, prefix: prefix) }
    }

    private func isInSubtree(_ name: String, prefix: String) -> Bool {
        name == prefix || name.hasPrefix(prefix + ":")
    }
}
