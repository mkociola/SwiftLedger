# SwiftLedger

A plain-text accounting library for Swift, implementing the [plain-text accounting](https://plaintextaccounting.org) (PTA) model popularised by [ledger-cli](https://ledger-cli.org) and [hledger](https://hledger.org).

SwiftLedger parses `.ledger` / `.journal` files, enforces double-entry balance rules, and provides balance queries, reports, and persistence — designed to be embedded in iOS and macOS apps.

> **Compatibility:** SwiftLedger supports a useful subset of the ledger-cli file format. Round-tripping preserves blank lines, comments, and directives, but elided posting amounts are written back as explicit values and formatting is normalised.

## Requirements

- Swift 6.0+
- iOS 17+ / macOS 14+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mkociola/SwiftLedger", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftLedger"]),
]
```

Or in Xcode: **File → Add Package Dependencies…**, paste the URL above.

## Quick start

### Parse an existing journal file

```swift
import SwiftLedger

let text    = try String(contentsOf: fileURL, encoding: .utf8)
let parser  = JournalParser()
let journal = try parser.parse(text)
let ledger  = Ledger(journal: journal)

// Exact-account balance
let checking = ledger.balance(for: "Assets:Checking")  // [Amount]

// Subtree total (all Expenses:* combined)
let totalExpenses = ledger.subtreeBalance(forPrefix: "Expenses")

// All transactions in a date range
let jan = ledger.transactions(
    from: JournalDate(year: 2024, month: 1, day: 1),
    to:   JournalDate(year: 2024, month: 1, day: 31)
)
```

### Build a ledger programmatically

```swift
var ledger = Ledger()

let tx = try Transaction(
    date:        JournalDate(year: 2024, month: 6, day: 1),
    description: "Coffee",
    postings: [
        Posting(accountName: "Expenses:Food",
                amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true)),
        Posting(accountName: "Assets:Cash",
                amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true)),
    ]
)
ledger.add(.transaction(tx))

// Remove a mistakenly added transaction
ledger.remove(.transaction(tx))
```

See [`Examples/sample.ledger`](Examples/sample.ledger) for a complete journal file.

## Plain-text format

```ledger
; Full-line comments start with ; or #

; Optional account declarations
account Assets:Checking
account Income:Salary

; Transactions: DATE [=AUXDATE] [* | !] [(CODE)] DESCRIPTION [  ; comment]
;     [* | !] ACCOUNT  AMOUNT [  ; comment]
;     [* | !] ACCOUNT  (elided — computed automatically)

2024-01-15 * Salary received
    Assets:Checking        $3200.00
    Income:Salary                     ; elided: -$3200.00 computed

2024-01-20 ! Pending refund  ; pending status
    Assets:Checking        $35.00
    Expenses:Food:Restaurants

2024-02-10 (REF-042) Freelance payment
    Assets:Checking        800 USD
    Income:Freelance
```

Supported:
- Dates: `YYYY-MM-DD` or `YYYY/MM/DD`
- Amount formats: `$100`, `-$50`, `$-50`, `100 USD`, `£500.00`
- Status: `*` cleared, `!` pending
- Codes: `(REF-042)`
- One elided posting per transaction (amount computed to balance)
- `account NAME` directives (with optional type)
- Inline comments after two or more spaces + `;`

## Core concepts

### Account naming and types

Accounts are identified by name only — no pre-registration is required. Types are inferred automatically from the top-level name segment:

| Root word                      | Type           |
|-------------------------------|----------------|
| `Assets` / `Asset`            | `.asset`       |
| `Liabilities` / `Liability`   | `.liability`   |
| `Equity` / `Equities`         | `.equity`      |
| `Income` / `Revenue`          | `.revenue`     |
| `Expenses` / `Expense`        | `.expense`     |
| anything else                 | `.unclassified`|

> **Important:** `BalanceSheet` and `IncomeStatement` only include accounts with a recognised type. Name your accounts `Assets:Cash`, not `Cash`, or they will not appear in reports.

Use `account NAME` directives to override the inferred type:

```ledger
account Cash
  ; Without a directive this becomes .unclassified.
  ; With explicit type (not yet parsed from directives) use Account(name:type:) programmatically.
```

`Account` exposes helpers useful for SwiftUI tree views:

```swift
let a = Account(name: "Expenses:Food:Groceries")
a.shortName  // "Groceries"
a.parent     // "Expenses:Food"
a.type       // .expense
```

### Transaction and Posting

`Transaction` is immutable and validated on creation:

```swift
// ✅ Balanced
let tx = try Transaction(
    date:        JournalDate(year: 2024, month: 3, day: 5),
    description: "Groceries",
    postings: [
        Posting(accountName: "Expenses:Food",
                amount: Amount(quantity:  87.45, commodity: "$", commodityIsPrefix: true)),
        Posting(accountName: "Assets:Checking",
                amount: Amount(quantity: -87.45, commodity: "$", commodityIsPrefix: true)),
    ]
)

// ❌ Throws LedgerError.unbalancedTransaction
let bad = try Transaction(
    date: JournalDate(year: 2024, month: 3, day: 5),
    description: "Oops",
    postings: [
        Posting(accountName: "Expenses:Food",
                amount: Amount(quantity: 100, commodity: "$", commodityIsPrefix: true)),
        Posting(accountName: "Assets:Checking",
                amount: Amount(quantity:  -50, commodity: "$", commodityIsPrefix: true)),
    ]
)
```

**Signs:** amounts are signed `Decimal` values. Positive = value flowing *into* an account; negative = value flowing *out*.

`Transaction` conforms to `Identifiable` (stable `id: UUID`) for safe use in SwiftUI lists.

### Amount

```swift
let price = Amount(quantity: Decimal(string: "19.99")!, commodity: "$", commodityIsPrefix: true)
let tax   = Amount(quantity: Decimal(string: "1.60")!,  commodity: "$", commodityIsPrefix: true)
let total = price + tax        // $21.59 — exact Decimal arithmetic, no floating-point error

// Different commodities: precondition failure (programmer error, not recoverable)
// let bad = usd + eur         // ← crashes with a clear message

let scaled = price * 3         // $59.97
```

Group a collection by commodity:

```swift
let postings: [Posting] = ...
let nets = postings.map(\.amount).netByCommodity()  // one Amount per commodity
```

### JournalDate

`JournalDate` is a timezone-free year/month/day value — it avoids the off-by-one errors that `Foundation.Date` can introduce near midnight with timezone conversions.

```swift
let d = JournalDate(year: 2024, month: 6, day: 15)
JournalDate.today   // today's local date
```

## Balance queries

All queries are on `Ledger`, which is a pure value type and can be snapshotted or passed across threads freely.

```swift
// Exact account
let balance: [Amount] = ledger.balance(for: "Assets:Checking")

// Subtree total (e.g. all Expenses:Food:* plus Expenses:Food itself)
let foodTotal: [Amount] = ledger.subtreeBalance(forPrefix: "Expenses:Food")

// All balances as of a date
let snapshot = ledger.allBalances(asOf: JournalDate(year: 2024, month: 12, day: 31))

// Transactions for one account
let txs = ledger.transactions(for: "Assets:Checking")

// Transactions in subtree
let expTxs = ledger.transactions(forPrefix: "Expenses")

// Date range
let q1 = ledger.transactions(
    from: JournalDate(year: 2024, month: 1, day: 1),
    to:   JournalDate(year: 2024, month: 3, day: 31)
)
```

## Reports

All reports are pure value types computed from a `Ledger` snapshot.

### BalanceSheet

```swift
let bs = BalanceSheet(ledger: ledger)
print(bs.isBalanced)  // true for any well-formed double-entry journal

for entry in bs.assets {
    let qty = entry.quantity(for: "$") ?? 0
    print(entry.account.shortName, qty)
}
// Also: bs.liabilities, bs.equity
```

`BalanceSheet` accepts an optional `asOf: JournalDate` to show the position at a past date.

### IncomeStatement

```swift
let statement = IncomeStatement(
    ledger: ledger,
    from: JournalDate(year: 2024, month: 1, day: 1),
    to:   JournalDate(year: 2024, month: 12, day: 31)
)

for entry in statement.revenues  { print(entry.account.name, entry.amounts) }
for entry in statement.expenses  { print(entry.account.name, entry.amounts) }
print(statement.netIncome)  // [Amount] per commodity
```

### AccountStatement

Running balance for one account, useful for a bank-statement view:

```swift
let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Checking")

for line in stmt.lines {
    print(line.transaction.date, line.transaction.description)
    print("  posting:", line.posting.amount)
    print("  balance:", line.runningBalance)
}
```

### AccountBalance

Reports return `[AccountBalance]`. Each value has:

```swift
entry.account          // Account — name, type, shortName, parent
entry.amounts          // [Amount] — one per commodity
entry.quantity(for: "$")  // Decimal? — convenience accessor
```

## Persistence

Implement `LedgerStore` to plug in any storage backend:

```swift
public protocol LedgerStore: Sendable {
    func load() throws -> Ledger
    func save(_ ledger: Ledger) throws
}
```

### PlainTextJournalStore

Reads and writes a `.ledger` file on disk using an atomic write:

```swift
let store   = PlainTextJournalStore(url: fileURL)
let manager = try LedgerManager(store: store)
```

### InMemoryLedgerStore

Non-persistent, in-memory store — ideal for unit tests and SwiftUI previews:

```swift
let store = InMemoryLedgerStore(ledger: .sampleData)

#Preview {
    LedgerView(store: store)
}
```

### Custom store (SwiftData / CloudKit)

```swift
actor SwiftDataStore: LedgerStore {
    func load() throws -> Ledger {
        // fetch from SwiftData, build Journal, return Ledger
    }
    func save(_ ledger: Ledger) throws {
        // serialize ledger.journal.items, persist via SwiftData
    }
}
```

## Concurrency

`LedgerManager` is a Swift actor — it serialises all access and persists changes automatically after each mutation.

```swift
// init is synchronous (throws if store.load() fails)
let manager = try LedgerManager(store: PlainTextJournalStore(url: fileURL))

// queries — await only
let txs = await manager.transactions(forPrefix: "Expenses")
let bs  = await manager.balanceSheet()

// mutations — try await (store.save can throw)
try await manager.add(.transaction(tx))
try await manager.remove(.transaction(tx))

// reload from disk (e.g. after external edit)
try await manager.reload()
```

The same API is available as non-`async` methods on `Ledger` for synchronous use cases (e.g. inside another actor or when persistence is not needed).

## Running the tests

```bash
swift test
```

## License

MIT

