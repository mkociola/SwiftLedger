# SwiftLedger

A double-entry bookkeeping library for Swift. Designed to be embedded in iOS and macOS apps.

## What is double-entry bookkeeping?

Every financial transaction affects **two accounts** — one is debited, one is credited — and the totals must always balance. This is the foundation of all modern accounting (and how banks, ERPs, and accounting software work under the hood).

SwiftLedger enforces this rule at the type level: **a `Transaction` cannot be created if debits ≠ credits.** The initializer throws, making an unbalanced ledger unrepresentable.

## Requirements

- Swift 6.0+
- iOS 17+ / macOS 14+

## Installation

### Swift Package Manager

Add this to your app's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mkociola/SwiftLedger", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftLedger"]),
]
```

Or in Xcode: **File → Add Package Dependencies…**, paste the URL above and click **Add Package**.

## Quick start

```swift
import SwiftLedger

// 1. Create a ledger
var ledger = Ledger()

// 2. Register accounts
let cash    = Account(name: "Cash",    type: .asset,   currency: "USD")
let equity  = Account(name: "Equity",  type: .equity,  currency: "USD")
let revenue = Account(name: "Revenue", type: .revenue, currency: "USD")
let expense = Account(name: "Expense", type: .expense, currency: "USD")

try ledger.addAccount(cash)
try ledger.addAccount(equity)
try ledger.addAccount(revenue)
try ledger.addAccount(expense)

// 3. Post transactions
try ledger.post(Transaction(memo: "Owner investment", entries: [
    .debit(account: cash,   amount: Money(1000, "USD")),
    .credit(account: equity, amount: Money(1000, "USD")),
]))

try ledger.post(Transaction(memo: "Service revenue", entries: [
    .debit(account: cash,     amount: Money(300, "USD")),
    .credit(account: revenue, amount: Money(300, "USD")),
]))

try ledger.post(Transaction(memo: "Rent", entries: [
    .debit(account: expense, amount: Money(200, "USD")),
    .credit(account: cash,   amount: Money(200, "USD")),
]))

// 4. Query balances
let cashBalance = try ledger.balance(for: cash.id)
print(cashBalance.netBalance)           // 1100 USD

// 5. Check the ledger is still in balance
print(ledger.trialBalance().isBalanced) // true
```

## Core concepts

### Account types

| Type        | Normal balance | Examples                        |
|-------------|----------------|---------------------------------|
| `.asset`    | Debit          | Cash, inventory, receivables    |
| `.liability`| Credit         | Loans, accounts payable         |
| `.equity`   | Credit         | Owner's capital, retained earnings |
| `.revenue`  | Credit         | Sales, service income           |
| `.expense`  | Debit          | Rent, salaries, utilities       |

### Money

`Money` wraps `Decimal` (not `Double`) to avoid floating-point rounding errors.

```swift
let price = Money(Decimal(string: "19.99")!, "USD")
let tax   = Money(Decimal(string: "1.60")!, "USD")
let total = try price + tax  // 21.59 USD — exact
```

### Transactions

Transactions are immutable and validated on creation:

```swift
// ✅ Balanced — works fine
try Transaction(memo: "Sale", entries: [
    .debit(account: cash,     amount: Money(100, "USD")),
    .credit(account: revenue, amount: Money(100, "USD")),
])

// ❌ Unbalanced — throws LedgerError.unbalanced
try Transaction(memo: "Oops", entries: [
    .debit(account: cash,     amount: Money(100, "USD")),
    .credit(account: revenue, amount: Money(50, "USD")),
])
```

## Reports

All reports are pure value types computed from a `Ledger` snapshot.

### Balance Sheet

Assets = Liabilities + Equity

```swift
let bs = BalanceSheet(ledger: ledger, currency: "USD")
print(bs.totalAssets)              // 1100 USD
print(bs.totalLiabilitiesAndEquity)
print(bs.isBalanced)               // true
```

### Income Statement (P&L)

```swift
let is_ = IncomeStatement(ledger: ledger, from: startDate, to: endDate, currency: "USD")
print(is_.totalRevenue)   // 300 USD
print(is_.totalExpenses)  // 200 USD
print(is_.netIncome)      // 100 USD
print(is_.isProfit)       // true
```

### Account Statement

Running balance for a single account:

```swift
let stmt = try AccountStatement(ledger: ledger, accountID: cash.id)
for line in stmt.lines {
    print(line.transaction.memo, line.runningBalance)
}
print(stmt.closingBalance) // 1100 USD
```

## Persistence

The library is storage-agnostic. Conform to `LedgerStore` in your app to plug in SwiftData, CoreData, or any other backend:

```swift
actor MySwiftDataStore: LedgerStore {
    func load() async throws -> Ledger { /* load from SwiftData */ }
    func save(_ ledger: Ledger) async throws { /* save to SwiftData */ }
}
```

`InMemoryLedgerStore` is provided as a reference implementation — useful for unit tests and SwiftUI previews.

```swift
#Preview {
    LedgerView(store: InMemoryLedgerStore(initial: .sampleData))
}
```

## Running the tests

```bash
swift test
```

## License

MIT
