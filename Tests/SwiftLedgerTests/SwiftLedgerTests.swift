import Testing
import Foundation
@testable import SwiftLedger

// MARK: - Money Tests

@Suite("Money") struct MoneyTests {
    @Test func addSameCurrency() throws {
        let a = Money(100, "USD")
        let b = Money(50, "USD")
        let result = try a + b
        #expect(result.amount == 150)
        #expect(result.currency == "USD")
    }

    @Test func subtractSameCurrency() throws {
        let result = try Money(100, "USD") - Money(30, "USD")
        #expect(result.amount == 70)
    }

    @Test func multiplyByScalar() {
        let result = Money(20, "EUR") * 3
        #expect(result.amount == 60)
    }

    @Test func addDifferentCurrenciesThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Money(10, "USD") + Money(10, "EUR")
        }
    }

    @Test func negated() {
        #expect(Money(42, "USD").negated.amount == -42)
    }

    @Test func currencyNormalizesToUppercase() {
        #expect(Money(1, "usd").currency == "USD")
    }

    @Test func codableRoundTrip() throws {
        let original = Money(Decimal(string: "99.99")!, "USD")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Money.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Transaction Tests

@Suite("Transaction") struct TransactionTests {
    let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
    let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")

    @Test func balancedTransactionSucceeds() throws {
        let tx = try Transaction(
            memo: "Sale",
            entries: [
                try .debit(account: cash, amount: Money(100, "USD")),
                try .credit(account: revenue, amount: Money(100, "USD")),
            ]
        )
        #expect(tx.entries.count == 2)
        #expect(tx.memo == "Sale")
    }

    @Test func unbalancedTransactionThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Transaction(
                memo: "Bad",
                entries: [
                    try .debit(account: cash, amount: Money(100, "USD")),
                    try .credit(account: revenue, amount: Money(50, "USD")),
                ]
            )
        }
    }

    @Test func emptyTransactionThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Transaction(memo: "Empty", entries: [])
        }
    }

    @Test func mixedCurrenciesThrow() {
        #expect(throws: LedgerError.self) {
            _ = try Transaction(
                memo: "Multi-currency",
                entries: [
                    try .debit(account: cash, amount: Money(100, "USD")),
                    try .credit(account: revenue, amount: Money(100, "EUR")),
                ]
            )
        }
    }
}

// MARK: - Ledger Tests

@Suite("Ledger") struct LedgerTests {
    func makeLedger() throws -> (ledger: Ledger, cash: Account, revenue: Account, expense: Account) {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        let expense = Account(name: "Expense", type: .expense, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)
        try ledger.addAccount(expense)
        return (ledger, cash, revenue, expense)
    }

    @Test func postAndBalance() throws {
        var (ledger, cash, revenue, _) = try makeLedger()
        let tx = try Transaction(
            memo: "Sale",
            entries: [
                try .debit(account: cash, amount: Money(200, "USD")),
                try .credit(account: revenue, amount: Money(200, "USD")),
            ]
        )
        try ledger.post(tx)

        let cashBalance = try ledger.balance(for: cash.id)
        #expect(cashBalance.netBalance.amount == 200)

        let revenueBalance = try ledger.balance(for: revenue.id)
        #expect(revenueBalance.netBalance.amount == 200)
    }

    @Test func trialBalanceIsBalanced() throws {
        var (ledger, cash, revenue, _) = try makeLedger()
        let tx = try Transaction(
            memo: "Sale",
            entries: [
                try .debit(account: cash, amount: Money(500, "USD")),
                try .credit(account: revenue, amount: Money(500, "USD")),
            ]
        )
        try ledger.post(tx)
        #expect(ledger.trialBalance().isBalanced)
    }

    @Test func duplicateAccountThrows() throws {
        var ledger = Ledger()
        let acc = Account(name: "Cash", type: .asset, currency: "USD")
        try ledger.addAccount(acc)
        #expect(throws: LedgerError.self) {
            try ledger.addAccount(acc)
        }
    }

    @Test func unknownAccountBalanceThrows() throws {
        let ledger = Ledger()
        #expect(throws: LedgerError.self) {
            _ = try ledger.balance(for: UUID())
        }
    }

    @Test func transactionHistoryFiltered() throws {
        var (ledger, cash, revenue, _) = try makeLedger()
        let tx = try Transaction(
            memo: "Sale",
            entries: [
                try .debit(account: cash, amount: Money(100, "USD")),
                try .credit(account: revenue, amount: Money(100, "USD")),
            ]
        )
        try ledger.post(tx)
        let history = try ledger.transactions(for: cash.id)
        #expect(history.count == 1)
        #expect(history[0].memo == "Sale")
    }
}

// MARK: - Report Tests

@Suite("Reports") struct ReportTests {
    func populatedLedger() throws -> Ledger {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let equity  = Account(name: "Equity",  type: .equity,  currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        let expense = Account(name: "Expense", type: .expense, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(equity)
        try ledger.addAccount(revenue)
        try ledger.addAccount(expense)

        // Owner invests $1000
        try ledger.post(Transaction(
            memo: "Owner investment",
            entries: [
                try .debit(account: cash, amount: Money(1000, "USD")),
                try .credit(account: equity, amount: Money(1000, "USD")),
            ]
        ))
        // Earn $300 revenue
        try ledger.post(Transaction(
            memo: "Service revenue",
            entries: [
                try .debit(account: cash, amount: Money(300, "USD")),
                try .credit(account: revenue, amount: Money(300, "USD")),
            ]
        ))
        // Spend $100 on expense
        try ledger.post(Transaction(
            memo: "Rent",
            entries: [
                try .credit(account: cash, amount: Money(100, "USD")),
                try .debit(account: expense, amount: Money(100, "USD")),
            ]
        ))
        return ledger
    }

    @Test func balanceSheetBalances() throws {
        let ledger = try populatedLedger()
        let bs = BalanceSheet(ledger: ledger, currency: "USD")
        // Assets = 1200, Liabilities = 0, Equity = 1000, Net Income = 200
        #expect(bs.totalAssets.amount == 1200)
        #expect(bs.netIncome.amount == 200)
        #expect(bs.isBalanced)
    }

    @Test func incomeStatementNetIncome() throws {
        let ledger = try populatedLedger()
        let now = Date()
        let past = now.addingTimeInterval(-86400 * 365)
        let future = now.addingTimeInterval(86400)
        let is_ = IncomeStatement(ledger: ledger, from: past, to: future, currency: "USD")
        #expect(is_.totalRevenue.amount == 300)
        #expect(is_.totalExpenses.amount == 100)
        #expect(is_.netIncome.amount == 200)
        #expect(is_.isProfit)
    }

    @Test func accountStatementRunningBalance() throws {
        let ledger = try populatedLedger()
        let cash = ledger.chartOfAccounts.all.first(where: { $0.name == "Cash" })!
        let stmt = try AccountStatement(ledger: ledger, accountID: cash.id)
        // 3 transactions touch cash: +1000, +300, -100 = 1200
        #expect(stmt.closingBalance.amount == 1200)
        #expect(stmt.lines.count == 3)
    }
}

// MARK: - InMemoryLedgerStore Tests

@Suite("InMemoryLedgerStore") struct StoreTests {
    @Test func saveAndLoad() async throws {
        var ledger = Ledger()
        let acc = Account(name: "Cash", type: .asset, currency: "USD")
        try ledger.addAccount(acc)

        let store = InMemoryLedgerStore()
        try await store.save(ledger)
        let loaded = try await store.load()
        #expect(loaded.chartOfAccounts.count == 1)
    }
}

// MARK: - Subtree Balance Tests

@Suite("Subtree Balances") struct SubtreeBalanceTests {
    func makeLedger() throws -> Ledger {
        var ledger = Ledger()
        let cash        = Account(name: "Assets:Cash",               type: .asset,   currency: "USD")
        let groceries   = Account(name: "Expenses:Food:Groceries",   type: .expense, currency: "USD")
        let dining      = Account(name: "Expenses:Food:Dining Out",  type: .expense, currency: "USD")
        let rent        = Account(name: "Expenses:Housing:Rent",     type: .expense, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(groceries)
        try ledger.addAccount(dining)
        try ledger.addAccount(rent)

        try ledger.post(Transaction(memo: "Groceries", entries: [
            try .debit(account: groceries, amount: Money(80, "USD")),
            try .credit(account: cash,     amount: Money(80, "USD")),
        ]))
        try ledger.post(Transaction(memo: "Dinner", entries: [
            try .debit(account: dining, amount: Money(45, "USD")),
            try .credit(account: cash,  amount: Money(45, "USD")),
        ]))
        try ledger.post(Transaction(memo: "Rent", entries: [
            try .debit(account: rent, amount: Money(1200, "USD")),
            try .credit(account: cash, amount: Money(1200, "USD")),
        ]))
        return ledger
    }

    @Test func subtreeIncludesAllChildren() throws {
        let ledger = try makeLedger()
        let balances = ledger.subtreeBalances(forPrefix: "Expenses:Food")
        #expect(balances.count == 2)
        let total = balances.reduce(Decimal.zero) { $0 + $1.netBalance.amount }
        #expect(total == 125) // 80 + 45
    }

    @Test func subtreeExcludesUnrelatedAccounts() throws {
        let ledger = try makeLedger()
        let names = ledger.subtreeBalances(forPrefix: "Expenses:Food").map(\.account.name)
        #expect(!names.contains("Expenses:Housing:Rent"))
    }

    @Test func subtreeIncludesExactPrefixMatch() throws {
        var ledger = try makeLedger()
        let food = Account(name: "Expenses:Food", type: .expense, currency: "USD")
        try ledger.addAccount(food)
        let balances = ledger.subtreeBalances(forPrefix: "Expenses:Food")
        #expect(balances.count == 3)
    }

    @Test func prefixDoesNotMatchPartialSegment() throws {
        let ledger = try makeLedger()
        // "Expenses:Foo" must NOT match "Expenses:Food:Groceries"
        let balances = ledger.subtreeBalances(forPrefix: "Expenses:Foo")
        #expect(balances.isEmpty)
    }

    @Test func emptyPrefixReturnsNothing() throws {
        let ledger = try makeLedger()
        // A blank prefix shouldn't match everything via accidental hasPrefix("") == true
        let balances = ledger.subtreeBalances(forPrefix: "")
        #expect(balances.isEmpty)
    }

    @Test func chartOfAccountsWithPrefix() throws {
        let ledger = try makeLedger()
        let accounts = ledger.chartOfAccounts.accounts(withPrefix: "Expenses:Food")
        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.name.hasPrefix("Expenses:Food") })
    }
}

// MARK: - Entry Validation Tests

@Suite("Entry Validation") struct EntryValidationTests {
    let cash = Account(name: "Cash", type: .asset, currency: "USD")
    let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")

    @Test func zeroAmountThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Entry.debit(account: cash, amount: Money(.zero, "USD"))
        }
    }

    @Test func negativeAmountThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Entry.debit(account: cash, amount: Money(-10, "USD"))
        }
    }

    @Test func currencyMismatchThrows() {
        #expect(throws: LedgerError.self) {
            _ = try Entry.debit(account: cash, amount: Money(10, "EUR"))
        }
    }
}

// MARK: - Reversal Tests

@Suite("Transaction Reversal") struct ReversalTests {
    @Test func reversalPostsEqualOppositeEntries() throws {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)

        let tx = try Transaction(memo: "Sale", entries: [
            try .debit(account: cash,    amount: Money(100, "USD")),
            try .credit(account: revenue, amount: Money(100, "USD")),
        ])
        try ledger.post(tx)
        try ledger.reverse(tx)

        // After reversal both accounts should be back to zero
        #expect(try ledger.balance(for: cash.id).netBalance.amount == 0)
        #expect(try ledger.balance(for: revenue.id).netBalance.amount == 0)
        #expect(ledger.trialBalance().isBalanced)
    }

    @Test func reversedTransactionHasDefaultMemo() throws {
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        let tx = try Transaction(memo: "Sale", entries: [
            try .debit(account: cash,    amount: Money(100, "USD")),
            try .credit(account: revenue, amount: Money(100, "USD")),
        ])
        let reversed = try tx.reversed()
        #expect(reversed.memo == "Reversal of: Sale")
    }

    @Test func reversingUnpostedTransactionThrows() throws {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)

        let unposted = try Transaction(memo: "Not posted", entries: [
            try .debit(account: cash,    amount: Money(100, "USD")),
            try .credit(account: revenue, amount: Money(100, "USD")),
        ])
        #expect(throws: LedgerError.self) {
            try ledger.reverse(unposted)
        }
    }
}

// MARK: - Historical Balance Tests

@Suite("Historical Balances") struct HistoricalBalanceTests {
    @Test func balanceAsOfExcludesFutureTransactions() throws {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)

        let past   = Date(timeIntervalSinceNow: -86400 * 30) // 30 days ago
        let future = Date(timeIntervalSinceNow:  86400 * 30) // 30 days from now
        let cutoff = Date(timeIntervalSinceNow: -86400 * 10) // 10 days ago

        let oldTx = try Transaction(date: past, memo: "Old sale", entries: [
            try .debit(account: cash,    amount: Money(500, "USD")),
            try .credit(account: revenue, amount: Money(500, "USD")),
        ])
        let newTx = try Transaction(date: future, memo: "Future sale", entries: [
            try .debit(account: cash,    amount: Money(200, "USD")),
            try .credit(account: revenue, amount: Money(200, "USD")),
        ])
        try ledger.post(oldTx)
        try ledger.post(newTx)

        let balanceAtCutoff = try ledger.balance(for: cash.id, asOf: cutoff)
        #expect(balanceAtCutoff.netBalance.amount == 500)

        let currentBalance = try ledger.balance(for: cash.id)
        #expect(currentBalance.netBalance.amount == 700)
    }
}

// MARK: - Account Removal Tests

@Suite("Account Removal") struct AccountRemovalTests {
    @Test func canRemoveUnusedAccount() throws {
        var ledger = Ledger()
        let acc = Account(name: "Unused", type: .asset, currency: "USD")
        try ledger.addAccount(acc)
        try ledger.removeAccount(id: acc.id)
        #expect(ledger.chartOfAccounts.count == 0)
    }

    @Test func cannotRemoveAccountWithTransactions() throws {
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)
        try ledger.post(Transaction(memo: "Sale", entries: [
            try .debit(account: cash,    amount: Money(100, "USD")),
            try .credit(account: revenue, amount: Money(100, "USD")),
        ]))
        #expect(throws: LedgerError.self) {
            try ledger.removeAccount(id: cash.id)
        }
    }
}

// MARK: - FileLedgerStore Tests

@Suite("FileLedgerStore") struct FileLedgerStoreTests {
    @Test func saveAndLoadRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "test-ledger-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileLedgerStore(url: url)

        var ledger = Ledger()
        let cash = Account(name: "Cash", type: .asset, currency: "USD")
        try ledger.addAccount(cash)
        try await store.save(ledger)

        let loaded = try await store.load()
        #expect(loaded.chartOfAccounts.count == 1)
        #expect(loaded.chartOfAccounts.all.first?.name == "Cash")
    }

    @Test func loadMissingFileReturnsEmptyLedger() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "nonexistent-\(UUID()).json")
        let store = FileLedgerStore(url: url)
        let ledger = try await store.load()
        #expect(ledger.chartOfAccounts.isEmpty)
    }

    @Test func transactionDateRoundTripPreservesSubseconds() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "test-ledger-dates-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileLedgerStore(url: url)
        var ledger = Ledger()
        let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
        let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
        try ledger.addAccount(cash)
        try ledger.addAccount(revenue)

        // Use a date with sub-second precision
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let tx = try Transaction(date: date, memo: "Precision test", entries: [
            try .debit(account: cash,    amount: Money(1, "USD")),
            try .credit(account: revenue, amount: Money(1, "USD")),
        ])
        try ledger.post(tx)
        try await store.save(ledger)

        let loaded = try await store.load()
        let loadedDate = loaded.journal.transactions.first!.date
        // Dates must be equal within 1 millisecond
        #expect(abs(loadedDate.timeIntervalSince(date)) < 0.001)
    }
}

// MARK: - Decodable Validation Tests

@Suite("Decodable Validation") struct DecodableValidationTests {
    @Test func decodingInvalidCurrencyInMoneyThrows() throws {
        let json = #"{"amount":"100","currency":"INVALID"}"#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Money.self, from: data)
        }
    }

    @Test func decodingInvalidCurrencyInAccountThrows() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Cash","type":"asset","description":"","currency":"XX"}"#
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Account.self, from: data)
        }
    }

    @Test func decodingValidMoneySucceeds() throws {
        let json = #"{"amount":42.5,"currency":"EUR"}"#
        let data = json.data(using: .utf8)!
        let money = try JSONDecoder().decode(Money.self, from: data)
        #expect(money.currency == "EUR")
        #expect(money.amount == Decimal(string: "42.5")!)
    }
}
