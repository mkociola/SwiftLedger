/// An actor that provides serialised access to a `Ledger` and optional persistence.
public actor LedgerManager {
    private var ledger: Ledger
    private let store:  (any LedgerStore)?

    public init(store: (any LedgerStore)? = nil) throws {
        self.store  = store
        self.ledger = try store?.load() ?? Ledger()
    }

    // MARK: - Mutations

    public func post(_ transaction: Transaction) throws {
        ledger.post(transaction)
        try store?.save(ledger)
    }

    public func addAccountDirective(_ directive: AccountDirective) throws {
        ledger.addAccountDirective(directive)
        try store?.save(ledger)
    }

    // MARK: - Queries

    public func accounts() -> [Account] {
        ledger.accounts
    }

    public func balance(for accountName: String, asOf: JournalDate? = nil) -> [Amount] {
        ledger.balance(for: accountName, asOf: asOf)
    }

    public func subtreeBalance(forPrefix prefix: String, asOf: JournalDate? = nil) -> [Amount] {
        ledger.subtreeBalance(forPrefix: prefix, asOf: asOf)
    }

    public func transactions(for accountName: String) -> [Transaction] {
        ledger.transactions(for: accountName)
    }

    public func transactions(forPrefix prefix: String) -> [Transaction] {
        ledger.transactions(forPrefix: prefix)
    }

    public func transactions(from: JournalDate? = nil, to: JournalDate? = nil) -> [Transaction] {
        ledger.transactions(from: from, to: to)
    }

    public func balanceSheet(asOf: JournalDate? = nil) -> BalanceSheet {
        BalanceSheet(ledger: ledger, asOf: asOf)
    }

    public func incomeStatement(from: JournalDate? = nil, to: JournalDate? = nil) -> IncomeStatement {
        IncomeStatement(ledger: ledger, from: from, to: to)
    }

    public func accountStatement(for accountName: String, from: JournalDate? = nil, to: JournalDate? = nil) -> AccountStatement {
        AccountStatement(ledger: ledger, accountName: accountName, from: from, to: to)
    }

    /// Reloads from the store if one is present.
    public func reload() throws {
        guard let s = store else { return }
        ledger = try s.load()
    }
}
