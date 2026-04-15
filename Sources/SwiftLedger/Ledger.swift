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

    /// Posts a new transaction to the journal (appends to the AST).
    public mutating func post(_ transaction: Transaction) {
        journal.append(.transaction(transaction))
    }

    /// Appends an `account` directive.
    public mutating func addAccountDirective(_ directive: AccountDirective) {
        journal.append(.accountDirective(directive))
    }

    // MARK: - Accounts

    /// All accounts inferred from posting names, merged with any explicit
    /// `account` directives. Sorted by name.
    public var accounts: [Account] {
        var seen: [String: Account] = [:]

        // Explicit directives take precedence for type metadata.
        for d in journal.accountDirectives {
            let a = Account(name: d.name, type: d.type)
            seen[d.name] = a
        }

        // Infer from postings.
        for t in journal.transactions {
            for p in t.postings {
                if seen[p.accountName] == nil {
                    seen[p.accountName] = Account(name: p.accountName)
                }
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
        filteredTransactions { t in
            t.postings.contains { $0.accountName == accountName }
        }
    }

    /// Returns transactions that contain at least one posting in the account
    /// subtree rooted at `prefix`.
    public func transactions(forPrefix prefix: String) -> [Transaction] {
        filteredTransactions { t in
            t.postings.contains { isInSubtree($0.accountName, prefix: prefix) }
        }
    }

    /// Returns all transactions within an optional date range (inclusive).
    public func transactions(from: JournalDate? = nil, to: JournalDate? = nil) -> [Transaction] {
        filteredTransactions { t in
            if let from = from, t.date < from { return false }
            if let to   = to,   t.date > to   { return false }
            return true
        }
    }

    // MARK: - Private helpers

    private func filteredTransactions(_ predicate: (Transaction) -> Bool) -> [Transaction] {
        journal.transactions.filter(predicate)
    }

    private func postings(for accountName: String, asOf: JournalDate?) -> [Posting] {
        journal.transactions
            .filter { asOf == nil || $0.date <= asOf! }
            .flatMap(\.postings)
            .filter { $0.accountName == accountName }
    }

    private func postingsInSubtree(prefix: String, asOf: JournalDate?) -> [Posting] {
        journal.transactions
            .filter { asOf == nil || $0.date <= asOf! }
            .flatMap(\.postings)
            .filter { isInSubtree($0.accountName, prefix: prefix) }
    }

    private func isInSubtree(_ name: String, prefix: String) -> Bool {
        name == prefix || name.hasPrefix(prefix + ":")
    }
}
