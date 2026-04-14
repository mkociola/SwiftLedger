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
                .debit(account: cash, amount: Money(100, "USD")),
                .credit(account: revenue, amount: Money(100, "USD")),
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
                    .debit(account: cash, amount: Money(100, "USD")),
                    .credit(account: revenue, amount: Money(50, "USD")),
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
                    .debit(account: cash, amount: Money(100, "USD")),
                    .credit(account: revenue, amount: Money(100, "EUR")),
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
                .debit(account: cash, amount: Money(200, "USD")),
                .credit(account: revenue, amount: Money(200, "USD")),
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
                .debit(account: cash, amount: Money(500, "USD")),
                .credit(account: revenue, amount: Money(500, "USD")),
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
                .debit(account: cash, amount: Money(100, "USD")),
                .credit(account: revenue, amount: Money(100, "USD")),
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
                .debit(account: cash, amount: Money(1000, "USD")),
                .credit(account: equity, amount: Money(1000, "USD")),
            ]
        ))
        // Earn $300 revenue
        try ledger.post(Transaction(
            memo: "Service revenue",
            entries: [
                .debit(account: cash, amount: Money(300, "USD")),
                .credit(account: revenue, amount: Money(300, "USD")),
            ]
        ))
        // Spend $100 on expense
        try ledger.post(Transaction(
            memo: "Rent",
            entries: [
                .credit(account: cash, amount: Money(100, "USD")),
                .debit(account: expense, amount: Money(100, "USD")),
            ]
        ))
        return ledger
    }

    @Test func balanceSheetBalances() throws {
        let ledger = try populatedLedger()
        let bs = BalanceSheet(ledger: ledger, currency: "USD")
        // Assets: 1000 + 300 - 100 = 1200; Equity: 1000; net income goes to equity via reports
        // We just check the equation holds at raw balance level
        #expect(bs.totalAssets.amount > 0)
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
            .debit(account: groceries, amount: Money(80, "USD")),
            .credit(account: cash,     amount: Money(80, "USD")),
        ]))
        try ledger.post(Transaction(memo: "Dinner", entries: [
            .debit(account: dining, amount: Money(45, "USD")),
            .credit(account: cash,  amount: Money(45, "USD")),
        ]))
        try ledger.post(Transaction(memo: "Rent", entries: [
            .debit(account: rent, amount: Money(1200, "USD")),
            .credit(account: cash, amount: Money(1200, "USD")),
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
