import XCTest
@testable import SwiftLedger

final class SwiftLedgerTests: XCTestCase {

    // MARK: - JournalDate

    func testJournalDateBasic() throws {
        let d = try JournalDate(year: 2024, month: 6, day: 15)
        XCTAssertEqual(d.description, "2024-06-15")
    }

    func testJournalDateComparable() throws {
        let d1 = try JournalDate(year: 2024, month: 1, day: 1)
        let d2 = try JournalDate(year: 2024, month: 12, day: 31)
        XCTAssertLessThan(d1, d2)
        XCTAssertGreaterThan(d2, d1)
        XCTAssertEqual(d1, d1)
    }

    func testJournalDateInvalid() {
        XCTAssertThrowsError(try JournalDate(year: 2024, month: 13, day: 1))
        XCTAssertThrowsError(try JournalDate(year: 2024, month: 0,  day: 1))
        XCTAssertThrowsError(try JournalDate(year: 2024, month: 1,  day: 0))
    }

    // MARK: - Amount

    func testAmountNegation() {
        let a = Amount(quantity: 100, commodity: "USD")
        XCTAssertEqual(a.negated.quantity, -100)
        XCTAssertEqual(a.negated.commodity, "USD")
    }

    func testAmountAddSameCommodity() throws {
        let a = Amount(quantity: 100, commodity: "USD")
        let b = Amount(quantity: 50, commodity: "USD")
        let c = try a + b
        XCTAssertEqual(c.quantity, 150)
    }

    func testAmountAddDifferentCommodityThrows() {
        let a = Amount(quantity: 100, commodity: "USD")
        let b = Amount(quantity: 50, commodity: "EUR")
        XCTAssertThrowsError(try a + b)
    }

    func testAmountNetByCommodity() {
        let amounts = [
            Amount(quantity: 100, commodity: "USD"),
            Amount(quantity: -30, commodity: "USD"),
            Amount(quantity: 50,  commodity: "EUR"),
        ]
        let nets = amounts.netByCommodity()
        let netUSD = nets.first { $0.commodity == "USD" }!
        let netEUR = nets.first { $0.commodity == "EUR" }!
        XCTAssertEqual(netUSD.quantity, 70)
        XCTAssertEqual(netEUR.quantity, 50)
    }

    func testAmountDescriptionPrefix() {
        let a = Amount(quantity: 42, commodity: "$", commodityIsPrefix: true)
        XCTAssertEqual(a.description, "$42")
    }

    func testAmountDescriptionSuffix() {
        let a = Amount(quantity: 42, commodity: "USD", commodityIsPrefix: false)
        XCTAssertEqual(a.description, "42 USD")
    }

    // MARK: - AccountType inference

    func testAccountTypeInference() {
        XCTAssertEqual(AccountType.inferred(from: "Assets:Checking"),            .asset)
        XCTAssertEqual(AccountType.inferred(from: "Asset:Cash"),                 .asset)
        XCTAssertEqual(AccountType.inferred(from: "Liabilities:Visa"),           .liability)
        XCTAssertEqual(AccountType.inferred(from: "Equity:OpeningBalance"),      .equity)
        XCTAssertEqual(AccountType.inferred(from: "Income:Salary"),              .revenue)
        XCTAssertEqual(AccountType.inferred(from: "Revenue:Consulting"),         .revenue)
        XCTAssertEqual(AccountType.inferred(from: "Expenses:Food"),              .expense)
        XCTAssertEqual(AccountType.inferred(from: "Expense:Rent"),               .expense)
        XCTAssertEqual(AccountType.inferred(from: "Suspense"),                   .unclassified)
    }

    // MARK: - Account

    func testAccountParentAndShortName() {
        let a = Account(name: "Expenses:Food:Groceries")
        XCTAssertEqual(a.parent, "Expenses:Food")
        XCTAssertEqual(a.shortName, "Groceries")
    }

    func testAccountNoParent() {
        let a = Account(name: "Assets")
        XCTAssertNil(a.parent)
        XCTAssertEqual(a.shortName, "Assets")
    }

    // MARK: - Transaction validation

    func testTransactionBalanced() throws {
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        let tx = try Transaction(
            date: d,
            description: "Test",
            postings: [
                Posting(accountName: "Assets:Checking",  amount: Amount(quantity: -100, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Expenses:Food",    amount: Amount(quantity:  100, commodity: "$", commodityIsPrefix: true)),
            ]
        )
        XCTAssertEqual(tx.postings.count, 2)
    }

    func testTransactionUnbalancedThrows() throws {
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        XCTAssertThrowsError(try Transaction(
            date: d,
            description: "Bad",
            postings: [
                Posting(accountName: "Assets:Checking",  amount: Amount(quantity: -100, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Expenses:Food",    amount: Amount(quantity:   50, commodity: "$", commodityIsPrefix: true)),
            ]
        ))
    }

    func testTransactionTooFewPostingsThrows() throws {
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        XCTAssertThrowsError(try Transaction(
            date: d,
            description: "Single",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: 100, commodity: "USD")),
            ]
        ))
    }

    func testTransactionMultiCommodityBalance() throws {
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        let tx = try Transaction(
            date: d,
            description: "Multi",
            postings: [
                Posting(accountName: "Assets:BTC",       amount: Amount(quantity: -1,   commodity: "BTC")),
                Posting(accountName: "Assets:USD",       amount: Amount(quantity:  100, commodity: "USD")),
                Posting(accountName: "Income:Gain",      amount: Amount(quantity: -100, commodity: "USD")),
                Posting(accountName: "Expenses:Fee",     amount: Amount(quantity:  1,   commodity: "BTC")),
            ]
        )
        XCTAssertEqual(tx.postings.count, 4)
    }

    // MARK: - JournalParser: basic parsing

    func testParseSimpleTransaction() throws {
        let text = """
2024-01-15 Coffee shop
    Expenses:Food:Coffee  $5.00
    Assets:Checking  $-5.00
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.transactions.count, 1)
        let tx = journal.transactions[0]
        XCTAssertEqual(tx.description, "Coffee shop")
        XCTAssertEqual(tx.date, try JournalDate(year: 2024, month: 1, day: 15))
        XCTAssertEqual(tx.postings.count, 2)
        XCTAssertEqual(tx.postings[0].accountName, "Expenses:Food:Coffee")
        XCTAssertEqual(tx.postings[0].amount.quantity, Decimal(5))
        XCTAssertEqual(tx.postings[0].amount.commodity, "$")
        XCTAssertTrue(tx.postings[0].amount.commodityIsPrefix)
    }

    func testParseElided() throws {
        let text = """
2024-01-15 Salary
    Assets:Checking  $3000.00
    Income:Salary
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        let tx = journal.transactions[0]
        XCTAssertEqual(tx.postings.count, 2)
        let income = tx.postings.first { $0.accountName == "Income:Salary" }!
        XCTAssertEqual(income.amount.quantity, Decimal(-3000))
    }

    func testParseSlashDate() throws {
        let text = """
2024/03/10 Test
    Assets:Cash  100 USD
    Expenses:Misc  -100 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.transactions[0].date, try JournalDate(year: 2024, month: 3, day: 10))
    }

    func testParseTransactionStatus() throws {
        let text = """
2024-01-01 * Cleared tx
    Assets:Cash  100 USD
    Income:Sales  -100 USD

2024-01-02 ! Pending tx
    Assets:Cash  50 USD
    Income:Sales  -50 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.transactions[0].status, .cleared)
        XCTAssertEqual(journal.transactions[1].status, .pending)
    }

    func testParseTransactionCode() throws {
        let text = """
2024-01-15 (CHQ1234) Payment
    Assets:Checking  -200 USD
    Liabilities:Visa  200 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.transactions[0].code, "CHQ1234")
    }

    func testParseComment() throws {
        let text = """
; This is a comment
2024-01-01 Test
    Assets:Cash  100 USD
    Income:Sales  -100 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.transactions.count, 1)
        let comments = journal.items.filter {
            if case .comment = $0 { return true }
            return false
        }
        XCTAssertFalse(comments.isEmpty)
    }

    func testParseAccountDirective() throws {
        let text = """
account Assets:Savings

2024-01-01 Test
    Assets:Cash  100 USD
    Assets:Savings  -100 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertEqual(journal.accountDirectives.count, 1)
        XCTAssertEqual(journal.accountDirectives[0].name, "Assets:Savings")
    }

    func testParseAuxDate() throws {
        let text = """
2024-01-01=2024-01-05 Test
    Assets:Cash  100 USD
    Income:Sales  -100 USD
"""
        let parser  = JournalParser()
        let journal = try parser.parse(text)
        XCTAssertNotNil(journal.transactions[0].auxDate)
        XCTAssertEqual(journal.transactions[0].auxDate, try JournalDate(year: 2024, month: 1, day: 5))
    }

    func testParseMultipleElidedThrows() throws {
        let text = """
2024-01-01 Bad
    Assets:Cash
    Income:Sales
"""
        let parser = JournalParser()
        XCTAssertThrowsError(try parser.parse(text))
    }

    // MARK: - Amount parsing

    func testAmountParserPrefixSymbol() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("$100.50", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(string: "100.50")!)
        XCTAssertEqual(a.commodity, "$")
        XCTAssertTrue(a.commodityIsPrefix)
    }

    func testAmountParserNegativePrefix() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("-$50", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(-50))
        XCTAssertEqual(a.commodity, "$")
    }

    func testAmountParserInnerNegative() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("$-50", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(-50))
        XCTAssertEqual(a.commodity, "$")
    }

    func testAmountParserSuffix() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("100.00 USD", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(string: "100.00")!)
        XCTAssertEqual(a.commodity, "USD")
        XCTAssertFalse(a.commodityIsPrefix)
    }

    func testAmountParserThousandSeparators() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("$1,000.00", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(string: "1000.00")!)
    }

    func testAmountParserPound() throws {
        let parser = JournalParser()
        let a = try parser.parseAmount("£500", lineNumber: 1)
        XCTAssertEqual(a.quantity, Decimal(500))
        XCTAssertEqual(a.commodity, "£")
        XCTAssertTrue(a.commodityIsPrefix)
    }

    // MARK: - Ledger queries

    func testLedgerBalance() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        let tx = try Transaction(
            date: d,
            description: "Groceries",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 50, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity: -50, commodity: "$", commodityIsPrefix: true)),
            ]
        )
        ledger.post(tx)

        let balance = ledger.balance(for: "Expenses:Food")
        XCTAssertEqual(balance.count, 1)
        XCTAssertEqual(balance[0].quantity, 50)
        XCTAssertEqual(balance[0].commodity, "$")
    }

    func testLedgerSubtreeBalance() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        ledger.post(try Transaction(
            date: d, description: "Coffee",
            postings: [
                Posting(accountName: "Expenses:Food:Coffee",    amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",             amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true)),
            ]
        ))
        ledger.post(try Transaction(
            date: d, description: "Groceries",
            postings: [
                Posting(accountName: "Expenses:Food:Groceries", amount: Amount(quantity: 30, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",             amount: Amount(quantity: -30, commodity: "$", commodityIsPrefix: true)),
            ]
        ))
        ledger.post(try Transaction(
            date: d, description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Housing",        amount: Amount(quantity: 1000, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",             amount: Amount(quantity: -1000, commodity: "$", commodityIsPrefix: true)),
            ]
        ))

        let foodBalance = ledger.subtreeBalance(forPrefix: "Expenses:Food")
        XCTAssertEqual(foodBalance[0].quantity, 35)

        let expBalance = ledger.subtreeBalance(forPrefix: "Expenses")
        XCTAssertEqual(expBalance[0].quantity, 1035)
    }

    func testLedgerHistoricalBalance() throws {
        var ledger = Ledger()
        let d1 = try JournalDate(year: 2024, month: 1, day: 1)
        let d2 = try JournalDate(year: 2024, month: 6, day: 1)
        ledger.post(try Transaction(
            date: d1, description: "Jan",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 50, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity: -50, commodity: "$", commodityIsPrefix: true)),
            ]
        ))
        ledger.post(try Transaction(
            date: d2, description: "June",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 75, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity: -75, commodity: "$", commodityIsPrefix: true)),
            ]
        ))

        let cutoff  = try JournalDate(year: 2024, month: 3, day: 1)
        let balance = ledger.balance(for: "Expenses:Food", asOf: cutoff)
        XCTAssertEqual(balance[0].quantity, 50)
    }

    func testLedgerTransactionsForPrefix() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        let food = try Transaction(
            date: d, description: "Food",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 20, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity: -20, commodity: "$", commodityIsPrefix: true)),
            ]
        )
        let rent = try Transaction(
            date: d, description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Housing", amount: Amount(quantity: 1000, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",      amount: Amount(quantity: -1000, commodity: "$", commodityIsPrefix: true)),
            ]
        )
        ledger.post(food)
        ledger.post(rent)

        let expTxs = ledger.transactions(forPrefix: "Expenses")
        XCTAssertEqual(expTxs.count, 2)

        let foodTxs = ledger.transactions(forPrefix: "Expenses:Food")
        XCTAssertEqual(foodTxs.count, 1)
        XCTAssertEqual(foodTxs[0].description, "Food")
    }

    func testLedgerInferredAccounts() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        ledger.post(try Transaction(
            date: d, description: "Test",
            postings: [
                Posting(accountName: "Expenses:Food:Groceries", amount: Amount(quantity: 50, commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Checking",         amount: Amount(quantity: -50, commodity: "$", commodityIsPrefix: true)),
            ]
        ))

        let names = ledger.accounts.map(\.name)
        XCTAssertTrue(names.contains("Expenses:Food:Groceries"))
        XCTAssertTrue(names.contains("Expenses:Food"))    // parent auto-inferred
        XCTAssertTrue(names.contains("Expenses"))          // grandparent auto-inferred
        XCTAssertTrue(names.contains("Assets:Checking"))
        XCTAssertTrue(names.contains("Assets"))
    }

    // MARK: - Serializer round-trip

    func testSerializerRoundTrip() throws {
        let text = """
2024-01-15 Coffee shop
    Expenses:Food:Coffee  $5.00
    Assets:Checking  $-5.00
"""
        let parser     = JournalParser()
        let journal    = try parser.parse(text)
        let serializer = JournalSerializer()
        let output     = serializer.serialize(journal)

        // Re-parse the output and verify the transaction is preserved
        let journal2   = try parser.parse(output)
        XCTAssertEqual(journal2.transactions.count, 1)
        XCTAssertEqual(journal2.transactions[0].description, "Coffee shop")
        XCTAssertEqual(journal2.transactions[0].postings.count, 2)
    }

    func testSerializerPreservesComments() throws {
        let text = """
; Opening balances

2024-01-01 Opening
    Assets:Cash  1000 USD
    Equity:Opening  -1000 USD
"""
        let parser     = JournalParser()
        let journal    = try parser.parse(text)
        let serializer = JournalSerializer()
        let output     = serializer.serialize(journal)

        XCTAssertTrue(output.contains("; Opening balances") || output.contains("Opening balances"))
    }

    // MARK: - PlainTextJournalStore

    func testPlainTextJournalStoreRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }

        // Create initial file content
        let text = """
2024-01-01 Opening
    Assets:Cash  1000 USD
    Equity:Opening  -1000 USD
"""
        try text.write(to: url, atomically: true, encoding: .utf8)

        let store  = PlainTextJournalStore(url: url)
        let loaded = try store.load()
        XCTAssertEqual(loaded.journal.transactions.count, 1)

        // Save and re-load
        var ledger = loaded
        let d = try JournalDate(year: 2024, month: 6, day: 1)
        ledger.post(try Transaction(
            date: d, description: "Coffee",
            postings: [
                Posting(accountName: "Expenses:Food", amount: Amount(quantity: 5,  commodity: "$", commodityIsPrefix: true)),
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true)),
            ]
        ))
        try store.save(ledger)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.journal.transactions.count, 2)
    }

    // MARK: - BalanceSheet

    func testBalanceSheetIsBalanced() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        ledger.post(try Transaction(
            date: d, description: "Salary",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity:  3000, commodity: "USD")),
                Posting(accountName: "Income:Salary",   amount: Amount(quantity: -3000, commodity: "USD")),
            ]
        ))
        let bs = BalanceSheet(ledger: ledger)
        XCTAssertTrue(bs.isBalanced)
        XCTAssertFalse(bs.assets.isEmpty)
    }

    // MARK: - IncomeStatement

    func testIncomeStatement() throws {
        var ledger = Ledger()
        let d1 = try JournalDate(year: 2024, month: 1, day: 1)
        let d2 = try JournalDate(year: 2024, month: 6, day: 1)
        ledger.post(try Transaction(
            date: d1, description: "Salary",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity:  3000, commodity: "USD")),
                Posting(accountName: "Income:Salary",   amount: Amount(quantity: -3000, commodity: "USD")),
            ]
        ))
        ledger.post(try Transaction(
            date: d1, description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Rent",   amount: Amount(quantity:  1000, commodity: "USD")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -1000, commodity: "USD")),
            ]
        ))

        let cutoff = try JournalDate(year: 2024, month: 3, day: 1)
        let is1    = IncomeStatement(ledger: ledger, to: cutoff)
        XCTAssertFalse(is1.revenues.isEmpty)
        XCTAssertFalse(is1.expenses.isEmpty)

        let afterCutoff = IncomeStatement(ledger: ledger, from: d2)
        XCTAssertTrue(afterCutoff.revenues.isEmpty)
    }

    // MARK: - AccountStatement

    func testAccountStatement() throws {
        var ledger = Ledger()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        ledger.post(try Transaction(
            date: d, description: "Deposit",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity:  1000, commodity: "USD")),
                Posting(accountName: "Equity:Opening",  amount: Amount(quantity: -1000, commodity: "USD")),
            ]
        ))
        ledger.post(try Transaction(
            date: d, description: "Coffee",
            postings: [
                Posting(accountName: "Expenses:Food",   amount: Amount(quantity:  5, commodity: "USD")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -5, commodity: "USD")),
            ]
        ))

        let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Checking")
        XCTAssertEqual(stmt.lines.count, 2)
        XCTAssertEqual(stmt.lines[0].runningBalance[0].quantity, 1000)
        XCTAssertEqual(stmt.lines[1].runningBalance[0].quantity, 995)
    }

    // MARK: - LedgerManager

    func testLedgerManagerPost() async throws {
        let manager = try LedgerManager()
        let d = try JournalDate(year: 2024, month: 1, day: 1)
        try await manager.post(Transaction(
            date: d, description: "Test",
            postings: [
                Posting(accountName: "Assets:Cash",   amount: Amount(quantity:  100, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -100, commodity: "USD")),
            ]
        ))
        let txs = await manager.transactions(for: "Assets:Cash")
        XCTAssertEqual(txs.count, 1)
    }
}
