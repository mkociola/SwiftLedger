/// A per-account, per-period balance matrix: the substrate behind
/// multi-period (hledger-style `balance -M`) reports.
///
/// One row per account, each carrying an **opening** balance — everything
/// posted strictly before the first bucket — and one **change** entry per
/// bucket. Closing balances are the running sum of the two, so cumulative
/// and historical presentations are derivable without a second pass over the
/// journal; see `Row.endingBalances()`.
///
/// Build one with `Ledger.balanceMatrix(bucketStarts:to:including:)`, which
/// documents the bucketing and zero conventions.
public struct BalanceMatrix: Sendable, Codable, Equatable {
    /// One account's line in the matrix.
    public struct Row: Sendable, Codable, Equatable {
        /// The account, typed by its `account` directive when one declares
        /// it and by name inference otherwise — same precedence as
        /// `Ledger.accounts`.
        public let account: Account
        /// Net balance from every posting dated strictly before the first
        /// bucket start, one `Amount` per commodity, sorted by commodity.
        /// Empty when the account has no history before the window.
        public let opening: [Amount]
        /// Net postings within each bucket, parallel to
        /// `BalanceMatrix.bucketStarts`. Each entry holds one `Amount` per
        /// commodity posted in that bucket, sorted by commodity; a bucket
        /// with no postings at all is `[]`, while a bucket whose postings
        /// cancel out keeps an explicit zero `Amount`.
        public let changes: [[Amount]]

        public init(account: Account, opening: [Amount], changes: [[Amount]]) {
            self.account = account
            self.opening = opening
            self.changes = changes
        }

        /// The closing balance at the end of each bucket: `opening` plus every
        /// change up to and including that bucket, netted by commodity and
        /// sorted by commodity.
        ///
        /// This is the cumulative/historical view of the row. It is derived
        /// arithmetic, not a second journal scan — O(buckets × commodities).
        public func endingBalances() -> [[Amount]] {
            var running = opening
            return changes.map { bucket in
                running = (running + bucket).netByCommodity()
                return running
            }
        }

        /// The closing balance at the end of the final bucket, or `opening`
        /// when the matrix has no buckets.
        ///
        /// Folds the row once rather than building every intermediate closing
        /// balance the way `endingBalances()` does.
        public func endingBalance() -> [Amount] {
            (opening + changes.joined()).netByCommodity()
        }
    }

    /// The ascending bucket start dates the matrix was built for. Bucket `i`
    /// covers `bucketStarts[i]` through the day before `bucketStarts[i + 1]`;
    /// the last bucket runs through `to`.
    public let bucketStarts: [JournalDate]
    /// The inclusive end of the final bucket.
    public let to: JournalDate // swiftlint:disable:this identifier_name
    /// One row per account with at least one posting the matrix can see,
    /// sorted by account name.
    public let rows: [Row]

    /// Creates a matrix, sorting `rows` by account name — the order `rows`
    /// documents and `subscript(_:)` binary-searches.
    public init(
        bucketStarts: [JournalDate],
        to: JournalDate, // swiftlint:disable:this identifier_name
        rows: [Row],
    ) {
        self.bucketStarts = bucketStarts
        self.to = to
        self.rows = rows.sorted { $0.account.name < $1.account.name }
    }

    /// Decodes a matrix, re-establishing the by-name row order that
    /// `subscript(_:)` binary-searches.
    ///
    /// Synthesised `Decodable` would take `rows` verbatim, so JSON written
    /// anywhere but by `encode(to:)` could otherwise yield a matrix whose
    /// lookups silently miss rows it holds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketStarts = try container.decode([JournalDate].self, forKey: .bucketStarts)
        to = try container.decode(JournalDate.self, forKey: .to)
        rows = try container
            .decode([Row].self, forKey: .rows)
            .sorted { $0.account.name < $1.account.name }
    }

    /// The number of buckets — `bucketStarts.count`, and the length of every
    /// row's `changes`.
    public var bucketCount: Int {
        bucketStarts.count
    }

    /// Row account names in the same (sorted) order as `rows`.
    public var accountNames: [String] {
        rows.map(\.account.name)
    }

    /// The row for an exact account name, or `nil` when no posting the matrix
    /// can see names that account.
    ///
    /// Rows are exact posting accounts — there is no parent roll-up, so
    /// `matrix["Expenses"]` is `nil` unless something posts to `Expenses`
    /// itself. Callers presenting a tree aggregate the rows they want.
    public subscript(accountName: String) -> Row? {
        var low = rows.startIndex
        var high = rows.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if rows[mid].account.name < accountName {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < rows.endIndex, rows[low].account.name == accountName else { return nil }
        return rows[low]
    }
}

public extension Ledger {
    /// Returns a per-account, per-period balance matrix in one pass over the
    /// journal: an opening balance per account plus that account's net
    /// postings in each bucket.
    ///
    /// `bucketStarts` are ascending bucket start dates: bucket `i` covers
    /// `bucketStarts[i]` through the day before `bucketStarts[i + 1]`, and the
    /// last bucket runs through `to` inclusive — the same contract as
    /// `incomeStatementSeries(bucketStarts:to:)`. A row's `opening` nets every
    /// posting dated strictly before `bucketStarts[0]`; postings dated after
    /// `to` land nowhere. An empty `bucketStarts` yields an empty matrix.
    ///
    /// **Zeros** follow `subtreeBalanceSeries(forPrefix:from:to:)` rather than
    /// `incomeStatementSeries`: netted amounts are kept even when they net to
    /// zero, so a bucket in which an account's postings cancel out is
    /// `[Amount(0, …)]`, distinct from the `[]` of a bucket the account had no
    /// postings in at all. Callers that want zero-net entries gone filter with
    /// `Amount.isZero`.
    ///
    /// **Rows** are exact posting accounts — one per account named by at least
    /// one posting the matrix can see, sorted by name, with no parent roll-up
    /// (aggregate subtrees caller-side). An account named only by postings that
    /// `including` excludes, or only by transactions dated after `to`, gets no
    /// row at all. Ordering within a bucket is irrelevant here — only sums are
    /// taken — so, unlike the transaction queries, nothing is sorted by date.
    ///
    /// **`including`** sees whole `Transaction`s, not individual postings: a
    /// transaction it rejects contributes nothing anywhere, opening included,
    /// and every posting of an accepted transaction counts. Filter on
    /// `description`, `status`, `code`, or anything else a `Transaction`
    /// carries. Posting-level filtering is out of scope: a predicate may read
    /// `postings`, but its verdict still applies to the whole transaction, so
    /// one whose postings carry their own `Posting.status` markers is all-in
    /// or all-out rather than split.
    ///
    /// Closing/cumulative balances are derivable from a single matrix without
    /// a second scan — see `BalanceMatrix.Row.endingBalances()`.
    ///
    /// A **single-bucket** matrix is the substrate for a *filtered* report: one
    /// bucket spanning the report range with an `including` predicate gives the
    /// per-account revenue and expense totals of an `IncomeStatement` (in
    /// `changes[0]`, filtered by `Row.account.type`), and `opening` plus that
    /// change gives the `BalanceSheet` position — neither of which accepts a
    /// filter of its own.
    ///
    /// This query is the general case, not the cheap one:
    /// `subtreeBalanceSeries(forPrefix:from:to:)` stays the better choice for
    /// one subtree's daily closing balances, and
    /// `incomeStatementSeries(bucketStarts:to:)` for unfiltered
    /// revenue/expense totals; both avoid building per-account rows.
    func balanceMatrix(
        bucketStarts: [JournalDate],
        to: JournalDate, // swiftlint:disable:this identifier_name
        including: (@Sendable (Transaction) -> Bool)? = nil,
    ) -> BalanceMatrix {
        guard !bucketStarts.isEmpty else {
            return BalanceMatrix(bucketStarts: [], to: to, rows: [])
        }

        let declaredTypes = directiveTypes
        // Per account: everything before the window, then one sum per bucket.
        var sums: [String: (opening: CommoditySums, changes: [CommoditySums])] = [:]
        let emptyBuckets = [CommoditySums](repeating: [:], count: bucketStarts.count)

        for transaction in journal.transactions {
            // Date first: the caller's predicate never runs on transactions
            // the window excludes anyway.
            guard transaction.date <= to else { continue }
            if let including, !including(transaction) { continue }
            // `nil` only for dates before the first start, which fold into the
            // opening balance.
            let bucket = Self.bucketIndex(for: transaction.date, in: bucketStarts)
            for posting in transaction.postings {
                let key = posting.accountName
                if let bucket {
                    Self.accumulate(
                        posting.amount, into: &sums[key, default: ([:], emptyBuckets)].changes[bucket],
                    )
                } else {
                    Self.accumulate(
                        posting.amount, into: &sums[key, default: ([:], emptyBuckets)].opening,
                    )
                }
            }
        }

        // `BalanceMatrix.init` sorts the rows by name.
        let rows = sums.map { name, account in
            BalanceMatrix.Row(
                account: Account(name: name, type: declaredTypes[name]),
                opening: Self.amounts(from: account.opening),
                changes: account.changes.map { Self.amounts(from: $0) },
            )
        }

        return BalanceMatrix(bucketStarts: bucketStarts, to: to, rows: rows)
    }
}
