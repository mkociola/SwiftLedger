import Foundation
@testable import SwiftLedger
import Testing

// swiftlint:disable file_length

// MARK: - Helpers

private func makeDate(_ year: Int, _ month: Int, _ day: Int) throws -> JournalDate {
    try JournalDate(year: year, month: month, day: day)
}

private func makeTx(
    date: JournalDate,
    description: String = "Test",
    debit: String = "Expenses:Food",
    credit: String = "Assets:Cash",
    amount: Decimal = 50,
    commodity: String = "USD",
) throws -> Transaction {
    try Transaction(
        date: date,
        description: description,
        postings: [
            Posting(accountName: debit, amount: Amount(quantity: amount, commodity: commodity)),
            Posting(accountName: credit, amount: Amount(quantity: -amount, commodity: commodity)),
        ],
    )
}

// MARK: - JournalDate

@Suite("JournalDate") struct JournalDateTests {
    @Test
    func `description formats as yyyy-MM-dd with zero-padding`() throws {
        #expect(try makeDate(2024, 6, 15).description == "2024-06-15")
        #expect(try makeDate(2024, 1, 5).description == "2024-01-05")
    }

    @Test
    func `comparison is strictly chronological`() throws {
        let earlier = try makeDate(2024, 1, 1)
        let later = try makeDate(2024, 12, 31)
        #expect(earlier < later)
        #expect(later > earlier)
        #expect(earlier == earlier)
        #expect(earlier != later)
    }

    @Test
    func `month out of 1–12 throws invalidDate with formatted string`() {
        #expect(throws: LedgerError.invalidDate("2024-13-01")) { try makeDate(2024, 13, 1) }
        #expect(throws: LedgerError.invalidDate("2024-00-01")) { try makeDate(2024, 0, 1) }
    }

    @Test
    func `day out of 1–31 throws invalidDate with formatted string`() {
        #expect(throws: LedgerError.invalidDate("2024-01-00")) { try makeDate(2024, 1, 0) }
        #expect(throws: LedgerError.invalidDate("2024-01-32")) { try makeDate(2024, 1, 32) }
    }
}

// MARK: - Amount

@Suite("Amount") struct AmountTests {
    @Test
    func `negation flips sign and preserves commodity and prefix flag`() {
        // swiftlint:disable identifier_name
        let a = Amount(quantity: 100, commodity: "USD", commodityIsPrefix: false)
        let n = a.negated
        // swiftlint:enable identifier_name
        #expect(n.quantity == -100)
        #expect(n.commodity == "USD")
        #expect(n.commodityIsPrefix == false)
    }

    @Test
    func `adding same commodity yields correct sum`() {
        // swiftlint:disable identifier_name
        let a = Amount(quantity: 100, commodity: "USD")
        let b = Amount(quantity: 50, commodity: "USD")
        let c = a + b
        // swiftlint:enable identifier_name
        #expect(c.quantity == 150)
        #expect(c.commodity == "USD")
    }

    @Test
    func `subtracting same commodity yields correct difference`() {
        // swiftlint:disable identifier_name
        let a = Amount(quantity: 100, commodity: "USD")
        let b = Amount(quantity: 30, commodity: "USD")
        let c = a - b
        // swiftlint:enable identifier_name
        #expect(c.quantity == 70)
        #expect(c.commodity == "USD")
    }

    @Test
    func `scalar multiplication scales quantity and preserves commodity`() {
        // swiftlint:disable identifier_name
        let a = Amount(quantity: 50, commodity: "USD")
        let b = a * 3
        // swiftlint:enable identifier_name
        #expect(b.quantity == 150)
        #expect(b.commodity == "USD")
    }

    @Test
    func `netByCommodity groups amounts and sums per commodity`() throws {
        let amounts = [
            Amount(quantity: 100, commodity: "USD"),
            Amount(quantity: -30, commodity: "USD"),
            Amount(quantity: 50, commodity: "EUR"),
        ]
        let nets = amounts.netByCommodity()
        let usd = try #require(nets.first { $0.commodity == "USD" })
        let eur = try #require(nets.first { $0.commodity == "EUR" })
        #expect(nets.count == 2)
        #expect(usd.quantity == 70)
        #expect(eur.quantity == 50)
    }

    @Test
    func `description places commodity before number when commodityIsPrefix`() {
        #expect(Amount(quantity: 42, commodity: "$", commodityIsPrefix: true).description == "$42")
    }

    @Test
    func `description places commodity after number when not commodityIsPrefix`() {
        #expect(Amount(quantity: 42, commodity: "USD", commodityIsPrefix: false).description == "42 USD")
    }

    @Test
    func `isZero is true only for zero quantity`() {
        #expect(Amount(quantity: 0, commodity: "USD").isZero)
        #expect(!Amount(quantity: 1, commodity: "USD").isZero)
        #expect(!Amount(quantity: -1, commodity: "USD").isZero)
    }
}

// MARK: - AccountType

@Suite("AccountType") struct AccountTypeTests {
    @Test
    func `infers asset, liability, equity, revenue, expense from root segment`() {
        #expect(AccountType.inferred(from: "Assets:Checking") == .asset)
        #expect(AccountType.inferred(from: "Asset:Cash") == .asset)
        #expect(AccountType.inferred(from: "Liabilities:Visa") == .liability)
        #expect(AccountType.inferred(from: "Liability:Loan") == .liability)
        #expect(AccountType.inferred(from: "Equity:OpeningBalance") == .equity)
        #expect(AccountType.inferred(from: "Income:Salary") == .revenue)
        #expect(AccountType.inferred(from: "Revenue:Consulting") == .revenue)
        #expect(AccountType.inferred(from: "Expenses:Food") == .expense)
        #expect(AccountType.inferred(from: "Expense:Rent") == .expense)
    }

    @Test
    func `unrecognised root segment infers unclassified`() {
        #expect(AccountType.inferred(from: "Suspense") == .unclassified)
        #expect(AccountType.inferred(from: "Temp:Holding") == .unclassified)
    }

    @Test
    func `inference is case-insensitive on the root segment`() {
        #expect(AccountType.inferred(from: "assets:Cash") == .asset)
        #expect(AccountType.inferred(from: "EXPENSES:Food") == .expense)
    }

    @Test
    func `displaySign is +1 for asset and expense, -1 for liability/equity/revenue`() {
        #expect(AccountType.asset.displaySign == 1)
        #expect(AccountType.expense.displaySign == 1)
        #expect(AccountType.liability.displaySign == -1)
        #expect(AccountType.equity.displaySign == -1)
        #expect(AccountType.revenue.displaySign == -1)
    }
}

// MARK: - Account

@Suite("Account") struct AccountTests {
    @Test
    func `parent is all segments except last; shortName is last segment`() {
        let account = Account(name: "Expenses:Food:Groceries")
        #expect(account.parent == "Expenses:Food")
        #expect(account.shortName == "Groceries")
    }

    @Test
    func `top-level account has nil parent and full name as shortName`() {
        let account = Account(name: "Assets")
        #expect(account.parent == nil)
        #expect(account.shortName == "Assets")
    }

    @Test
    func `type is inferred from name root when not specified`() {
        #expect(Account(name: "Assets:Checking").type == .asset)
        #expect(Account(name: "Expenses:Food").type == .expense)
    }

    @Test
    func `explicit type overrides name-based inference`() {
        let account = Account(name: "Suspense", type: .asset) // would infer .unclassified
        #expect(account.type == .asset)
    }
}

// MARK: - Transaction

@Suite("Transaction") struct TransactionTests {
    @Test
    func `balanced transaction stores all fields correctly`() throws {
        let date = try makeDate(2024, 1, 1)
        let transaction = try Transaction(
            date: date, status: .cleared, code: "CHQ001",
            description: "Groceries",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 50, commodity: "USD")),
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: -50, commodity: "USD")),
            ],
            comment: "weekly shop",
        )
        #expect(transaction.date == date)
        #expect(transaction.status == .cleared)
        #expect(transaction.code == "CHQ001")
        #expect(transaction.description == "Groceries")
        #expect(transaction.comment == "weekly shop")
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings[0].accountName == "Expenses:Food")
        #expect(transaction.postings[0].amount.quantity == 50)
        #expect(transaction.postings[1].accountName == "Assets:Cash")
        #expect(transaction.postings[1].amount.quantity == -50)
    }

    @Test
    func `unbalanced postings throw unbalancedTransaction with commodity and imbalance`() throws {
        let date = try makeDate(2024, 1, 1)
        // sum = -100 + 50 = -50 USD
        #expect(throws: LedgerError.unbalancedTransaction(commodity: "USD", imbalance: -50)) {
            try Transaction(
                date: date, description: "Bad",
                postings: [
                    Posting(accountName: "Assets:Cash", amount: Amount(quantity: -100, commodity: "USD")),
                    Posting(accountName: "Expenses:Food", amount: Amount(quantity: 50, commodity: "USD")),
                ],
            )
        }
    }

    @Test
    func `fewer than two postings throws emptyTransaction`() throws {
        let date = try makeDate(2024, 1, 1)
        #expect(throws: LedgerError.emptyTransaction) {
            try Transaction(
                date: date, description: "Single",
                postings: [Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD"))],
            )
        }
    }

    @Test
    func `multi-commodity balance is validated independently per commodity`() throws {
        let date = try makeDate(2024, 1, 1)
        let transaction = try Transaction(
            date: date, description: "BTC sale",
            postings: [
                Posting(accountName: "Assets:BTC", amount: Amount(quantity: -1, commodity: "BTC")),
                Posting(accountName: "Expenses:Fee", amount: Amount(quantity: 1, commodity: "BTC")),
                Posting(accountName: "Assets:USD", amount: Amount(quantity: 100, commodity: "USD")),
                Posting(accountName: "Income:Gain", amount: Amount(quantity: -100, commodity: "USD")),
            ],
        )
        let btcNet = transaction.postings.filter { $0.amount.commodity == "BTC" }.map(\.amount.quantity).reduce(0, +)
        let usdNet = transaction.postings.filter { $0.amount.commodity == "USD" }.map(\.amount.quantity).reduce(0, +)
        #expect(btcNet == 0)
        #expect(usdNet == 0)
    }

    @Test
    func `two independently constructed transactions receive different IDs`() throws {
        let date = try makeDate(2024, 1, 1)
        let transaction1 = try makeTx(date: date, description: "A")
        let transaction2 = try makeTx(date: date, description: "A")
        #expect(transaction1.id != transaction2.id)
    }

    @Test
    func `copying a struct value preserves the original ID`() throws {
        let original = try makeTx(date: makeDate(2024, 1, 1))
        let copy = original
        #expect(copy.id == original.id)
    }

    @Test
    func `explicit ID passed to init is stored as-is`() throws {
        let fixedID = UUID()
        let transaction = try Transaction(
            id: fixedID, date: makeDate(2024, 1, 1), description: "A",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 10, commodity: "USD")),
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: -10, commodity: "USD")),
            ],
        )
        #expect(transaction.id == fixedID)
    }
}

// MARK: - Journal

@Suite("Journal") struct JournalTests {
    @Test
    func `remove returns false when item is not present`() {
        var journal = Journal()
        let removed = journal.remove(.blank)
        #expect(!removed)
        #expect(journal.items.isEmpty)
    }

    @Test
    func `remove deletes only the first occurrence of a duplicate item`() {
        var journal = Journal(items: [.comment("note"), .comment("note"), .blank])
        let removed = journal.remove(.comment("note"))
        #expect(removed)
        #expect(journal.items.count == 2)
        #expect(journal.items[0] == .comment("note")) // second copy remains
        #expect(journal.items[1] == .blank)
    }

    @Test
    func `removing a transaction leaves all other items untouched`() throws {
        let transaction = try makeTx(date: makeDate(2024, 1, 1))
        var journal = Journal(items: [.comment("keep"), .transaction(transaction), .blank])
        let removed = journal.remove(.transaction(transaction))
        #expect(removed)
        #expect(journal.items.count == 2)
        #expect(journal.items[0] == .comment("keep"))
        #expect(journal.items[1] == .blank)
    }
}

// MARK: - JournalParser

@Suite("JournalParser") struct JournalParserTests {
    @Test
    func `parses description, date, account names, amounts, and prefix flag`() throws {
        let text = """
        2024-01-15 Coffee shop
            Expenses:Food:Coffee  $5.00
            Assets:Checking  $-5.00
        """
        let journal = try JournalParser().parse(text)
        let transaction = try #require(journal.transactions.first)
        #expect(journal.transactions.count == 1)
        #expect(transaction.description == "Coffee shop")
        #expect(try transaction.date == makeDate(2024, 1, 15))
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings[0].accountName == "Expenses:Food:Coffee")
        #expect(transaction.postings[0].amount.quantity == Decimal(string: "5.00")!)
        #expect(transaction.postings[0].amount.commodity == "$")
        #expect(transaction.postings[0].amount.commodityIsPrefix == true)
        #expect(transaction.postings[1].accountName == "Assets:Checking")
        #expect(transaction.postings[1].amount.quantity == Decimal(string: "-5.00")!)
    }

    @Test
    func `elided posting amount is resolved to the negative sum of explicit postings`() throws {
        let text = """
        2024-01-15 Salary
            Assets:Checking  $3000.00
            Income:Salary
        """
        let journal = try JournalParser().parse(text)
        let income = try #require(journal.transactions.first?.postings.first { $0.accountName == "Income:Salary" })
        #expect(income.amount.quantity == Decimal(-3000))
        #expect(income.amount.commodity == "$")
    }

    @Test
    func `slash-separated date is accepted and parsed correctly`() throws {
        let text = """
        2024/03/10 Test
            Assets:Cash  100 USD
            Expenses:Misc  -100 USD
        """
        let journal = try JournalParser().parse(text)
        #expect(try journal.transactions.first?.date == makeDate(2024, 3, 10))
    }

    @Test
    func `cleared (*) and pending (!) status markers are parsed`() throws {
        let text = """
        2024-01-01 * Cleared
            Assets:Cash  100 USD
            Income:Sales  -100 USD

        2024-01-02 ! Pending
            Assets:Cash  50 USD
            Income:Sales  -50 USD
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions[0].status == .cleared)
        #expect(journal.transactions[1].status == .pending)
    }

    @Test
    func `transaction code in parentheses is parsed`() throws {
        let text = """
        2024-01-15 (CHQ1234) Payment
            Assets:Checking  -200 USD
            Liabilities:Visa  200 USD
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.code == "CHQ1234")
    }

    @Test
    func `semicolon comment lines are stored as .comment items with their text`() throws {
        let text = """
        ; Opening note
        2024-01-01 Test
            Assets:Cash  100 USD
            Income:Sales  -100 USD
        """
        let journal = try JournalParser().parse(text)
        let comments = journal.items.compactMap { item -> String? in
            if case let .comment(text) = item { return text }
            return nil
        }
        #expect(comments.count == 1)
        #expect(comments[0] == "; Opening note")
    }

    @Test
    func `account directive stores account name`() throws {
        let text = """
        account Assets:Savings

        2024-01-01 Test
            Assets:Cash     100 USD
            Assets:Savings  -100 USD
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.accountDirectives.count == 1)
        #expect(journal.accountDirectives[0].name == "Assets:Savings")
    }

    @Test
    func `auxiliary date after = is parsed and stored on the transaction`() throws {
        let text = """
        2024-01-01=2024-01-05 Test
            Assets:Cash  100 USD
            Income:Sales  -100 USD
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(try transaction.auxDate == makeDate(2024, 1, 5))
    }

    @Test
    func `two elided postings in one transaction throws multipleElidedPostings`() {
        let text = """
        2024-01-01 Bad
            Assets:Cash
            Income:Sales
        """
        #expect(throws: LedgerError.multipleElidedPostings) { try JournalParser().parse(text) }
    }

    @Suite("amount parsing") struct AmountParsingTests {
        // swiftlint:disable identifier_name

        @Test
        func `prefix currency symbol with decimal quantity`() throws {
            let a = try JournalParser().parseAmount("$100.50", lineNumber: 1)
            #expect(a.quantity == Decimal(string: "100.50")!)
            #expect(a.commodity == "$")
            #expect(a.commodityIsPrefix == true)
        }

        @Test
        func `minus sign before prefix symbol negates the quantity`() throws {
            let a = try JournalParser().parseAmount("-$50", lineNumber: 1)
            #expect(a.quantity == -50)
            #expect(a.commodity == "$")
        }

        @Test
        func `minus sign between symbol and digits negates the quantity`() throws {
            let a = try JournalParser().parseAmount("$-50", lineNumber: 1)
            #expect(a.quantity == -50)
            #expect(a.commodity == "$")
        }

        @Test
        func `suffix commodity code follows the quantity`() throws {
            let a = try JournalParser().parseAmount("100.00 USD", lineNumber: 1)
            #expect(a.quantity == Decimal(string: "100.00")!)
            #expect(a.commodity == "USD")
            #expect(a.commodityIsPrefix == false)
        }

        @Test
        func `thousand separators are stripped from the numeric part`() throws {
            let a = try JournalParser().parseAmount("$1,000.00", lineNumber: 1)
            #expect(a.quantity == Decimal(string: "1000.00")!)
        }

        @Test
        func `pound sign is recognised as a prefix commodity symbol`() throws {
            let a = try JournalParser().parseAmount("£500", lineNumber: 1)
            #expect(a.quantity == 500)
            #expect(a.commodity == "£")
            #expect(a.commodityIsPrefix == true)
        }
        // swiftlint:enable identifier_name
    }
}

// MARK: - Ledger

@Suite("Ledger") struct LedgerTests {
    @Test
    func `balance returns net amount for exact account name`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(makeTx(date: date, debit: "Expenses:Food", credit: "Assets:Cash", amount: 50)))
        let bal = ledger.balance(for: "Expenses:Food")
        #expect(bal.count == 1)
        #expect(bal[0].quantity == 50)
        #expect(bal[0].commodity == "USD")
    }

    @Test
    func `subtree balance aggregates amounts across all sub-accounts`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(makeTx(
            date: date, debit: "Expenses:Food:Coffee", credit: "Assets:Cash", amount: 5,
        )))
        try ledger.add(.transaction(makeTx(
            date: date, debit: "Expenses:Food:Groceries", credit: "Assets:Cash", amount: 30,
        )))
        try ledger.add(.transaction(makeTx(date: date, debit: "Expenses:Housing", credit: "Assets:Cash", amount: 1000)))
        #expect(ledger.subtreeBalance(forPrefix: "Expenses:Food")[0].quantity == 35)
        #expect(ledger.subtreeBalance(forPrefix: "Expenses")[0].quantity == 1035)
    }

    @Test
    func `asOf cutoff excludes transactions dated after the cutoff`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let jun = try makeDate(2024, 6, 1)
        let cutoff = try makeDate(2024, 3, 1)
        try ledger.add(.transaction(makeTx(date: jan, debit: "Expenses:Food", credit: "Assets:Cash", amount: 50)))
        try ledger.add(.transaction(makeTx(date: jun, debit: "Expenses:Food", credit: "Assets:Cash", amount: 75)))
        let bal = ledger.balance(for: "Expenses:Food", asOf: cutoff)
        #expect(bal[0].quantity == 50) // only the January transaction
    }

    @Test
    func `transactions(forPrefix:) returns only transactions that touch that subtree`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        let food = try makeTx(
            date: date, description: "Food", debit: "Expenses:Food", credit: "Assets:Cash", amount: 20,
        )
        let rent = try makeTx(
            date: date, description: "Rent", debit: "Expenses:Housing", credit: "Assets:Cash", amount: 1000,
        )
        ledger.add(.transaction(food))
        ledger.add(.transaction(rent))
        #expect(ledger.transactions(forPrefix: "Expenses").count == 2)
        #expect(ledger.transactions(forPrefix: "Expenses:Food").count == 1)
        #expect(ledger.transactions(forPrefix: "Expenses:Food")[0].description == "Food")
    }

    @Test
    func `parent accounts are inferred automatically from posting names`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(makeTx(
            date: date, debit: "Expenses:Food:Groceries", credit: "Assets:Checking", amount: 50,
        )))
        let names = ledger.accounts.map(\.name)
        #expect(names.contains("Expenses:Food:Groceries"))
        #expect(names.contains("Expenses:Food"))
        #expect(names.contains("Expenses"))
        #expect(names.contains("Assets:Checking"))
        #expect(names.contains("Assets"))
    }

    @Test
    func `account directive explicit type overrides name-based type inference`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        // "Suspense" root would infer .unclassified; directive sets it to .asset
        ledger.add(.accountDirective(AccountDirective(name: "Suspense", type: .asset)))
        try ledger.add(.transaction(makeTx(date: date, debit: "Suspense", credit: "Assets:Cash", amount: 100)))
        let account = try #require(ledger.accounts.first { $0.name == "Suspense" })
        #expect(account.type == .asset)
    }

    @Test
    func `add then remove leaves the ledger without that transaction`() throws {
        var ledger = Ledger()
        let transaction = try makeTx(date: makeDate(2024, 1, 1))
        ledger.add(.transaction(transaction))
        #expect(ledger.journal.transactions.count == 1)
        let removed = ledger.remove(.transaction(transaction))
        #expect(removed)
        #expect(ledger.journal.transactions.isEmpty)
    }

    @Test
    func `remove returns false and does not alter the ledger when item is absent`() throws {
        var ledger = Ledger()
        let transaction = try makeTx(date: makeDate(2024, 1, 1))
        let removed = ledger.remove(.transaction(transaction))
        #expect(!removed)
        #expect(ledger.journal.items.isEmpty)
    }
}

// MARK: - JournalSerializer

@Suite("JournalSerializer") struct SerializerTests {
    @Test
    func `serialized output re-parses to a transaction with identical field values`() throws {
        let text = """
        2024-01-15 Coffee shop
            Expenses:Food:Coffee  $5.00
            Assets:Checking  $-5.00
        """
        let parser = JournalParser()
        let serializer = JournalSerializer()
        let journal1 = try parser.parse(text)
        let journal2 = try parser.parse(serializer.serialize(journal1))
        let transaction1 = try #require(journal1.transactions.first)
        let transaction2 = try #require(journal2.transactions.first)
        #expect(transaction2.date == transaction1.date)
        #expect(transaction2.description == transaction1.description)
        #expect(transaction2.postings.count == transaction1.postings.count)
        #expect(transaction2.postings[0].accountName == transaction1.postings[0].accountName)
        #expect(transaction2.postings[0].amount.quantity == transaction1.postings[0].amount.quantity)
        #expect(transaction2.postings[0].amount.commodity == transaction1.postings[0].amount.commodity)
        #expect(transaction2.postings[0].amount.commodityIsPrefix == transaction1.postings[0].amount.commodityIsPrefix)
    }

    @Test
    func `round-trip preserves status, code, aux date, comments, and account directives`() throws {
        let text = """
        ; Opening comment
        account Assets:Savings

        2024-01-01=2024-01-05 * (CHQ001) Salary
            Assets:Savings   3000 USD
            Income:Salary   -3000 USD
        """
        let parser = JournalParser()
        let serializer = JournalSerializer()
        let journal1 = try parser.parse(text)
        let journal2 = try parser.parse(serializer.serialize(journal1))

        let transaction = try #require(journal2.transactions.first)
        #expect(transaction.status == .cleared)
        #expect(transaction.code == "CHQ001")
        #expect(try transaction.auxDate == makeDate(2024, 1, 5))

        // Comments and directives must survive the round-trip
        let comments1 = journal1.items.filter { if case .comment = $0 { true } else { false } }
        let comments2 = journal2.items.filter { if case .comment = $0 { true } else { false } }
        #expect(comments1 == comments2)
        #expect(journal2.accountDirectives.first?.name == "Assets:Savings")
    }
}

// MARK: - PlainTextJournalStore

@Suite("PlainTextJournalStore") struct StoreTests {
    @Test
    func `loading a pre-existing file returns transactions with correct field values`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        2024-01-01 Opening
            Assets:Cash  1000 USD
            Equity:Opening  -1000 USD
        """.write(to: url, atomically: true, encoding: .utf8)

        let transaction = try #require(try PlainTextJournalStore(url: url).load().journal.transactions.first)
        #expect(transaction.description == "Opening")
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings[0].amount.quantity == 1000)
        #expect(transaction.postings[0].amount.commodity == "USD")
    }

    @Test
    func `saved ledger is reloaded with all transactions intact and values correct`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        2024-01-01 Opening
            Assets:Cash  1000 USD
            Equity:Opening  -1000 USD
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = PlainTextJournalStore(url: url)
        var ledger = try store.load()
        try ledger.add(.transaction(Transaction(
            date: makeDate(2024, 6, 1), description: "Coffee",
            postings: [
                Posting(accountName: "Expenses:Food",
                        amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",
                        amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true)),
            ],
        )))
        try store.save(ledger)

        let reloaded = try store.load()
        #expect(reloaded.journal.transactions.count == 2)
        let coffee = try #require(reloaded.journal.transactions.first { $0.description == "Coffee" })
        #expect(coffee.postings[0].amount.quantity == 5)
        #expect(coffee.postings[0].amount.commodity == "$")
    }
}

// MARK: - BalanceSheet

@Suite("BalanceSheet") struct BalanceSheetTests {
    @Test
    func `any well-formed double-entry journal satisfies isBalanced`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(makeTx(
            date: date, description: "Salary", debit: "Assets:Checking",
            credit: "Income:Salary", amount: 3000, commodity: "USD",
        )))
        #expect(BalanceSheet(ledger: ledger).isBalanced)
    }

    @Test
    func `asset account balance matches its posting amounts`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(makeTx(
            date: date, description: "Salary", debit: "Assets:Checking",
            credit: "Income:Salary", amount: 3000, commodity: "USD",
        )))
        let sheet = BalanceSheet(ledger: ledger)
        let checking = try #require(sheet.assets.first { $0.account.name == "Assets:Checking" })
        #expect(checking.amounts[0].quantity == 3000)
        #expect(checking.amounts[0].commodity == "USD")
    }
}

// MARK: - IncomeStatement

@Suite("IncomeStatement") struct IncomeStatementTests {
    private func ledgerWithSalaryAndRent() throws -> Ledger {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(Transaction(
            date: date, description: "Salary",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: 3000, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -3000, commodity: "USD")),
            ],
        )))
        try ledger.add(.transaction(Transaction(
            date: date, description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Rent", amount: Amount(quantity: 1000, commodity: "USD")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -1000, commodity: "USD")),
            ],
        )))
        return ledger
    }

    @Test
    func `revenue and expense account balances are correct`() throws {
        let stmt = try IncomeStatement(ledger: ledgerWithSalaryAndRent())
        let salary = try #require(stmt.revenues.first { $0.account.name == "Income:Salary" })
        let rent = try #require(stmt.expenses.first { $0.account.name == "Expenses:Rent" })
        #expect(salary.amounts[0].quantity == -3000) // revenue carried as negative
        #expect(rent.amounts[0].quantity == 1000)
    }

    @Test
    func `from/to date range excludes transactions outside the range`() throws {
        let afterAll = try makeDate(2024, 6, 1)
        let stmt = try IncomeStatement(ledger: ledgerWithSalaryAndRent(), from: afterAll)
        #expect(stmt.revenues.isEmpty)
        #expect(stmt.expenses.isEmpty)
    }

    @Test
    func `netIncome is revenue added to expenses (revenue negative + expense positive)`() throws {
        let stmt = try IncomeStatement(ledger: ledgerWithSalaryAndRent())
        let net = try #require(stmt.netIncome.first { $0.commodity == "USD" })
        // -3000 (revenue) + 1000 (expense) = -2000
        #expect(net.quantity == -2000)
    }
}

// MARK: - AccountStatement

@Suite("AccountStatement") struct AccountStatementTests {
    @Test
    func `lines appear in journal order with correct running balance after each posting`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(.transaction(Transaction(
            date: date, description: "Deposit",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: 1000, commodity: "USD")),
                Posting(accountName: "Equity:Opening", amount: Amount(quantity: -1000, commodity: "USD")),
            ],
        )))
        try ledger.add(.transaction(Transaction(
            date: date, description: "Coffee",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 5, commodity: "USD")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -5, commodity: "USD")),
            ],
        )))
        let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Checking")
        #expect(stmt.lines.count == 2)
        #expect(stmt.lines[0].transaction.description == "Deposit")
        #expect(stmt.lines[0].runningBalance[0].quantity == 1000)
        #expect(stmt.lines[1].transaction.description == "Coffee")
        #expect(stmt.lines[1].runningBalance[0].quantity == 995)
    }

    @Test
    func `to: date filter restricts statement lines to within the given range`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let jun = try makeDate(2024, 6, 1)
        let mar = try makeDate(2024, 3, 1)
        try ledger.add(.transaction(Transaction(
            date: jan, description: "Jan",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                Posting(accountName: "Income:A", amount: Amount(quantity: -100, commodity: "USD")),
            ],
        )))
        try ledger.add(.transaction(Transaction(
            date: jun, description: "Jun",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 200, commodity: "USD")),
                Posting(accountName: "Income:A", amount: Amount(quantity: -200, commodity: "USD")),
            ],
        )))
        let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Cash", to: mar)
        #expect(stmt.lines.count == 1)
        #expect(stmt.lines[0].transaction.description == "Jan")
    }
}

// MARK: - LedgerManager

@Suite("LedgerManager") struct LedgerManagerTests {
    @Test
    func `added transaction is reflected in ledger queries`() throws {
        let manager = try LedgerManager()
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "Salary",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -100, commodity: "USD")),
            ],
        )
        try manager.add(.transaction(transaction))
        let txs = manager.transactions(for: "Assets:Cash")
        #expect(txs.count == 1)
        #expect(txs[0].description == "Salary")
        #expect(txs[0].postings[0].amount.quantity == 100)
    }

    @Test
    func `removed transaction is no longer returned by queries`() throws {
        let manager = try LedgerManager()
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "Salary",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -100, commodity: "USD")),
            ],
        )
        try manager.add(.transaction(transaction))
        #expect(try manager.remove(.transaction(transaction)))
        #expect(manager.transactions(for: "Assets:Cash").isEmpty)
    }

    @Test
    func `remove returns false and does not call save when item is absent`() throws {
        let store = MockLedgerStore()
        let manager = try LedgerManager(store: store)
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "Ghost",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 1, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -1, commodity: "USD")),
            ],
        )
        #expect(try manager.remove(.transaction(transaction)) == false)
        #expect(store.saveCallCount == 0)
    }
}

// MARK: - Test doubles

private final class MockLedgerStore: LedgerStore {
    private(set) var saveCallCount = 0
    func load() throws -> Ledger {
        Ledger()
    }

    func save(_: Ledger) throws {
        saveCallCount += 1
    }
}
