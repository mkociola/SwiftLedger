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

/// A journal as a person would keep one: hand-aligned columns, thousands
/// separators, trailing zeros, tab indentation, an elided amount, a price and
/// an assertion. Nothing here is canonical, and all of it is valid.
private let handWrittenJournal = "; a journal written by hand, not by SwiftLedger\n"
    + "account Assets:Checking\n"
    + "\n"
    + "2024-01-15 * (CHQ001) Groceries  ; weekly shop\n"
    + "  Expenses:Food:Groceries      $1,234.50\n"
    + "  Assets:Checking             $-1,234.50\n"
    + "\n"
    + "2024-02-01 Buy shares\n"
    + "\tAssets:Brokerage  10 AAPL@$150.00 = 30 AAPL\n"
    + "\tAssets:Checking   $-1500.00\n"
    + "\n"
    + "2024-03-01 Salary\n"
    + "    Assets:Checking          3,000.00 EUR\n"
    + "    Income:Salary\n"
    + "\n"
    + "include other.ledger"

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
        #expect(
            Amount(quantity: 42, commodity: "USD", commodityIsPrefix: false).description == "42 USD",
        )
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
                postings: [
                    Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                ],
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
        let btcNet = transaction.postings.filter { $0.amount.commodity == "BTC" }.map(\.amount.quantity)
            .reduce(0, +)
        let usdNet = transaction.postings.filter { $0.amount.commodity == "USD" }.map(\.amount.quantity)
            .reduce(0, +)
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
    func `accountDirective(named:) finds a declaration whatever it carries`() throws {
        let journal = try JournalParser().parse("""
        account Expenses:Rent  ; declared but unused so far
        account Assets:Checking
        """)
        let found = try #require(journal.accountDirective(named: "Expenses:Rent"))
        #expect(found.comment == "declared but unused so far")
        #expect(journal.accountDirective(named: "Assets:Checking")?.comment == nil)
        // An account that only exists through its postings is not declared.
        #expect(journal.accountDirective(named: "Expenses:Food") == nil)
    }

    @Test
    func `removeAccountDirective(named:) removes a directive the caller cannot reconstruct`() throws {
        var journal = try JournalParser().parse("account Expenses:Rent  ; declared but unused so far")
        // Removing by value fails: the caller does not know the comment.
        let removedByValue = journal.remove(.accountDirective(AccountDirective(name: "Expenses:Rent")))
        #expect(!removedByValue)
        let directive = journal.removeAccountDirective(named: "Expenses:Rent")
        #expect(try #require(directive).comment == "declared but unused so far")
        #expect(journal.accountDirectives.isEmpty)
    }

    @Test
    func `removeAccountDirective(named:) returns nil and changes nothing when undeclared`() throws {
        var journal = try JournalParser().parse("account Assets:Checking")
        let removed = journal.removeAccountDirective(named: "Expenses:Rent")
        #expect(removed == nil)
        #expect(journal.items.count == 1)
    }

    @Test
    func `removeAccountDirective(named:) removes only the first of two declarations`() throws {
        var journal = try JournalParser().parse("""
        account Assets:Checking  ; first
        account Assets:Checking  ; second
        """)
        let removed = journal.removeAccountDirective(named: "Assets:Checking")
        #expect(removed?.comment == "first")
        #expect(journal.accountDirectives.map(\.comment) == ["second"])
    }

    @Test
    func `re-adding the removed directive restores the line exactly`() throws {
        let text = """
        account Expenses:Rent  ; declared but unused so far
        account Assets:Checking
        """
        var journal = try JournalParser().parse(text)
        let directive = journal.removeAccountDirective(named: "Expenses:Rent")
        try journal.append(.accountDirective(#require(directive)))
        #expect(JournalSerializer().serialize(journal) == """
        account Assets:Checking
        account Expenses:Rent  ; declared but unused so far
        """)
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
        let income = try #require(
            journal.transactions.first?.postings.first { $0.accountName == "Income:Salary" },
        )
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
    func `unsupported directives are kept verbatim, not turned into comments`() throws {
        let text = """
        include accounts.ledger
        !include prices/2024.ledger
        P 2024-01-01 AAPL $185.00
        commodity USD
            format $1,000.00
        alias Chk=Assets:Checking
        D $1,000.00
        year 2024
        apply account Personal
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.items.allSatisfy { if case .directive = $0 { true } else { false } })
        #expect(journal.directives == text.components(separatedBy: "\n"))
    }

    @Test
    func `an indented sub-directive keeps its indentation`() throws {
        let journal = try JournalParser().parse("account Assets:Checking\n    note Main account")
        #expect(journal.accountDirectives.map(\.name) == ["Assets:Checking"])
        #expect(journal.directives == ["    note Main account"])
    }

    @Test
    func `an indented comment line keeps its original indentation`() throws {
        let journal = try JournalParser().parse("    ; indented note")
        #expect(journal.items == [.comment("    ; indented note")])
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

    @Test
    func `account directive keeps its inline comment out of the account name`() throws {
        let text = "account Expenses:Rent  ; declared but unused so far"
        let journal = try JournalParser().parse(text)
        let directive = try #require(journal.accountDirectives.first)
        #expect(directive.name == "Expenses:Rent")
        #expect(directive.comment == "declared but unused so far")
        // The declared account must match the name postings actually use.
        #expect(Ledger(journal: journal).accounts.map(\.name) == ["Expenses", "Expenses:Rent"])
    }

    @Test
    func `an account directive without a comment keeps its whole name`() throws {
        let journal = try JournalParser().parse("account Assets:Checking")
        let directive = try #require(journal.accountDirectives.first)
        #expect(directive.name == "Assets:Checking")
        #expect(directive.comment == nil)
    }

    @Test
    func `an account line with no name is kept verbatim as a directive`() throws {
        let text = "account   ; nothing declared here"
        let journal = try JournalParser().parse(text)
        #expect(journal.accountDirectives.isEmpty)
        #expect(journal.directives == [text])
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

// MARK: - JournalParser: in-transaction comments

@Suite("in-transaction comments") struct InTransactionCommentTests {
    @Test
    func `an indented comment line is commentary, not a posting`() throws {
        let text = """
        2026-08-14 * Day trip — outbound
            Expenses:Transport  18.75 EUR
            ; TODO: split into Expenses:Misc:Fees later?
            Assets:Checking  -18.75 EUR
        """
        let journal = try JournalParser().parse(text)
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings.map(\.accountName) == ["Expenses:Transport", "Assets:Checking"])
        // No phantom account — nor a phantom parent per ":" — is invented
        // from the comment text.
        let names = Ledger(journal: journal).accounts.map(\.name)
        #expect(!names.contains(where: { $0.contains(";") }))
        #expect(names == ["Assets", "Assets:Checking", "Expenses", "Expenses:Transport"])
    }

    @Test
    func `two comment lines in one transaction parse instead of throwing`() throws {
        let text = """
        2026-01-01 * Opening balances
            ; imported from the old spreadsheet
            ; amounts reconciled against statements
            Assets:Cash  100.00 EUR
            Equity:Opening  -100.00 EUR
        """
        let journal = try JournalParser().parse(text)
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.count == 2)
        #expect(transaction.leadingComments == [
            "    ; imported from the old spreadsheet",
            "    ; amounts reconciled against statements",
        ])
    }

    @Test
    func `a comment before the first posting is kept on the transaction`() throws {
        let text = """
        2026-08-14 * Day trip — outbound
            ; paid in cash
            Expenses:Transport  18.75 EUR
            Assets:Checking  -18.75 EUR
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.leadingComments == ["    ; paid in cash"])
        #expect(transaction.postings.flatMap(\.trailingComments).isEmpty)
    }

    @Test
    func `a comment between two postings is kept on the posting above it`() throws {
        let text = """
        2026-08-14 * Day trip — outbound
            Expenses:Transport  18.75 EUR
            ; needs a category
            Assets:Checking  -18.75 EUR
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.leadingComments.isEmpty)
        #expect(transaction.postings[0].trailingComments == ["    ; needs a category"])
        #expect(transaction.postings[1].trailingComments.isEmpty)
    }

    @Test
    func `a single elided posting resolves to the balancing amount`() throws {
        let text = """
        2026-02-01 Salary
            Assets:Checking  3000.00 EUR
            Income:Salary
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings[1].accountName == "Income:Salary")
        #expect(transaction.postings[1].amount.quantity == Decimal(-3000))
        #expect(transaction.postings[1].amount.commodity == "EUR")
    }

    @Test
    func `an elided posting resolves when a comment shares the transaction`() throws {
        let text = """
        2026-08-14 * Day trip — outbound
            Expenses:Transport  18.75 EUR
            ; unlabelled entry — needs a category
            Assets:Checking
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 2)
        #expect(transaction.postings[1].accountName == "Assets:Checking")
        #expect(transaction.postings[1].amount.quantity == Decimal(string: "-18.75")!)
        #expect(transaction.postings[0].trailingComments.count == 1)
    }

    @Test
    func `an indented status marker starts a posting, not a comment`() throws {
        let text = """
        2026-03-01 Rent
            * Assets:Checking  -1200.00 EUR
            ! Expenses:Rent  1200.00 EUR
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.status) == [.cleared, .pending])
        #expect(transaction.postings.map(\.accountName) == ["Assets:Checking", "Expenses:Rent"])
        #expect(transaction.postings.flatMap(\.trailingComments).isEmpty)
    }

    @Test
    func `tab indentation and the hash marker are preserved verbatim`() throws {
        let text = "2026-03-01 Rent\n"
            + "\t; tab-indented note\n"
            + "    Assets:Checking  -1200.00 EUR\n"
            + "        # deeply indented, hash-marked\n"
            + "    Expenses:Rent  1200.00 EUR"
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.leadingComments == ["\t; tab-indented note"])
        #expect(transaction.postings[0].trailingComments == ["        # deeply indented, hash-marked"])
    }

    @Test
    func `a comment after the blank line ending a transaction stays top-level`() throws {
        let text = """
        2026-03-01 Rent
            Assets:Checking  -1200.00 EUR
            Expenses:Rent  1200.00 EUR

            ; not part of the transaction above
        """
        let journal = try JournalParser().parse(text)
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.flatMap(\.trailingComments).isEmpty)
        #expect(journal.items.last == .comment("    ; not part of the transaction above"))
    }
}

// MARK: - JournalParser: prices and balance assertions

@Suite("prices and balance assertions") struct PriceAndAssertionTests {
    @Test
    func `a per-unit price is parsed off the amount, not into its commodity`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00
            Assets:Checking   $-1500.00
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let share = transaction.postings[0]
        #expect(share.amount.quantity == 10)
        #expect(share.amount.commodity == "AAPL")
        #expect(share.price == .perUnit(Amount(quantity: 150, commodity: "$", commodityIsPrefix: true)))
        #expect(share.balanceAssertion == nil)
    }

    @Test
    func `a total price is kept as a total, not divided into a per-unit price`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @@ $1,500.00
            Assets:Checking   $-1500.00
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].price == .total(Amount(quantity: 1500, commodity: "$",
                                                               commodityIsPrefix: true)))
    }

    @Test
    func `a prefix-style balance assertion is parsed instead of being silently dropped`() throws {
        let text = """
        2024-01-01 Groceries
            Assets:Checking  $-100.00 = $500.00
            Expenses:Food    $100.00
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let checking = transaction.postings[0]
        #expect(checking.amount.quantity == -100)
        #expect(checking.balanceAssertion == Amount(quantity: 500, commodity: "$", commodityIsPrefix: true))
        #expect(checking.price == nil)
    }

    @Test
    func `a suffix-style balance assertion is parsed off the commodity name`() throws {
        let text = """
        2024-01-01 Groceries
            Assets:Checking  -100 EUR = 500 EUR
            Expenses:Food    100 EUR
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let checking = transaction.postings[0]
        #expect(checking.amount.commodity == "EUR")
        #expect(checking.balanceAssertion == Amount(quantity: 500, commodity: "EUR"))
    }

    @Test
    func `a price and an assertion on one posting are both parsed`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00 = 30 AAPL
            Assets:Checking   $-1500.00
        """
        let share = try #require(try JournalParser().parse(text).transactions.first?.postings.first)
        #expect(share.price == .perUnit(Amount(quantity: 150, commodity: "$", commodityIsPrefix: true)))
        #expect(share.balanceAssertion == Amount(quantity: 30, commodity: "AAPL"))
    }

    @Test
    func `a per-unit price balances the posting at what it cost`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00
            Assets:Checking   $-1500.00
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let balancing = transaction.postings[0].balancingAmount
        #expect(balancing.quantity == 1500)
        #expect(balancing.commodity == "$")
        // …and the AAPL quantity itself is still what the account holds.
        let ledger = try Ledger(journal: JournalParser().parse(text))
        #expect(ledger.balance(for: "Assets:Brokerage") == [Amount(quantity: 10, commodity: "AAPL")])
    }

    @Test
    func `a total price takes the sign of the posting it prices`() throws {
        let text = """
        2024-01-01 Sell shares
            Assets:Brokerage  -10 AAPL @@ $1500.00
            Assets:Checking   $1500.00
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].balancingAmount.quantity == -1500)
    }

    @Test
    func `an unbalanced priced transaction still throws`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00
            Assets:Checking   $-1000.00
        """
        #expect(throws: LedgerError.unbalancedTransaction(commodity: "$", imbalance: 500)) {
            try JournalParser().parse(text)
        }
    }

    @Test
    func `an elided amount resolves against what a priced posting cost`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00
            Assets:Checking
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[1].amount.quantity == -1500)
        #expect(transaction.postings[1].amount.commodity == "$")
    }

    @Test
    func `an assertion that disagrees with the balance is preserved, not rejected`() throws {
        // Assertions are carried, never checked: a journal claiming a balance
        // no posting supports must still load, unchanged.
        let text = """
        2024-01-01 Opening
            Assets:Cash     100 EUR = 999999 EUR
            Equity:Opening  -100 EUR
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].balanceAssertion == Amount(quantity: 999_999, commodity: "EUR"))
        let ledger = try Ledger(journal: JournalParser().parse(text))
        #expect(ledger.balance(for: "Assets:Cash") == [Amount(quantity: 100, commodity: "EUR")])
    }

    @Test
    func `prices and assertions survive a parse, serialise and re-parse`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00 = 30 AAPL
            Assets:Checking   $-1500.00

        2024-01-02 Sell shares
            Assets:Brokerage  -4 AAPL @@ $640.00
            Assets:Checking   $640.00
        """
        let parser = JournalParser()
        let journal = try parser.parse(JournalSerializer().serialize(parser.parse(text)))
        #expect(journal.transactions[0].postings[0].price
            == .perUnit(Amount(quantity: 150, commodity: "$", commodityIsPrefix: true)))
        #expect(journal.transactions[0].postings[0].balanceAssertion == Amount(quantity: 30, commodity: "AAPL"))
        #expect(journal.transactions[1].postings[0].price
            == .total(Amount(quantity: 640, commodity: "$", commodityIsPrefix: true)))
    }

    @Test
    func `a transaction built in code writes its price and assertion back canonically`() throws {
        let dollars = { (quantity: Decimal) in Amount(quantity: quantity, commodity: "$", commodityIsPrefix: true) }
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1),
            description: "Buy shares",
            postings: [
                Posting(
                    accountName: "Assets:Brokerage",
                    amount: Amount(quantity: 10, commodity: "AAPL"),
                    price: .perUnit(dollars(150)),
                    balanceAssertion: Amount(quantity: 30, commodity: "AAPL"),
                ),
                Posting(accountName: "Assets:Checking", amount: dollars(-1500)),
            ],
        )
        let text = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        // `$150.00`, not `$150`: nothing in this journal writes a dollar
        // amount, so the symbol's two-decimal default settles it.
        #expect(text.contains("10 AAPL @ $150.00 = 30 AAPL"))
        // …and it must come back meaning the same thing.
        let reparsed = try #require(try JournalParser().parse(text).transactions.first)
        #expect(reparsed.postings[0].price == transaction.postings[0].price)
        #expect(reparsed.postings[0].balanceAssertion == transaction.postings[0].balanceAssertion)
    }

    @Test
    func `a total price is written with the double marker that produced it`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1),
            description: "Buy shares",
            postings: [
                Posting(
                    accountName: "Assets:Brokerage",
                    amount: Amount(quantity: 10, commodity: "AAPL"),
                    price: .total(Amount(quantity: 1500, commodity: "$", commodityIsPrefix: true)),
                ),
                Posting(
                    accountName: "Assets:Checking",
                    amount: Amount(quantity: -1500, commodity: "$", commodityIsPrefix: true),
                ),
            ],
        )
        let text = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        #expect(text.contains("10 AAPL @@ $1500.00"))
        #expect(!text.contains("@@@"))
    }
}

// MARK: - Ledger

@Suite("Ledger") struct LedgerTests {
    @Test
    func `balance returns net amount for exact account name`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(makeTx(date: date, debit: "Expenses:Food", credit: "Assets:Cash", amount: 50)),
        )
        let bal = ledger.balance(for: "Expenses:Food")
        #expect(bal.count == 1)
        #expect(bal[0].quantity == 50)
        #expect(bal[0].commodity == "USD")
    }

    @Test
    func `subtree balance aggregates amounts across all sub-accounts`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(
                makeTx(
                    date: date, debit: "Expenses:Food:Coffee", credit: "Assets:Cash", amount: 5,
                ),
            ),
        )
        try ledger.add(
            .transaction(
                makeTx(
                    date: date, debit: "Expenses:Food:Groceries", credit: "Assets:Cash", amount: 30,
                ),
            ),
        )
        try ledger.add(
            .transaction(
                makeTx(date: date, debit: "Expenses:Housing", credit: "Assets:Cash", amount: 1000),
            ),
        )
        #expect(ledger.subtreeBalance(forPrefix: "Expenses:Food")[0].quantity == 35)
        #expect(ledger.subtreeBalance(forPrefix: "Expenses")[0].quantity == 1035)
    }

    @Test
    func `asOf cutoff excludes transactions dated after the cutoff`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let jun = try makeDate(2024, 6, 1)
        let cutoff = try makeDate(2024, 3, 1)
        try ledger.add(
            .transaction(makeTx(date: jan, debit: "Expenses:Food", credit: "Assets:Cash", amount: 50)),
        )
        try ledger.add(
            .transaction(makeTx(date: jun, debit: "Expenses:Food", credit: "Assets:Cash", amount: 75)),
        )
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
            date: date, description: "Rent", debit: "Expenses:Housing", credit: "Assets:Cash",
            amount: 1000,
        )
        ledger.add(.transaction(food))
        ledger.add(.transaction(rent))
        #expect(ledger.transactions(forPrefix: "Expenses").count == 2)
        #expect(ledger.transactions(forPrefix: "Expenses:Food").count == 1)
        #expect(ledger.transactions(forPrefix: "Expenses:Food")[0].description == "Food")
    }

    @Test
    func `transaction queries return date order for a journal written out of order`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let feb = try makeDate(2024, 2, 1)
        let mar = try makeDate(2024, 3, 1)
        try ledger.add(.transaction(makeTx(date: mar, description: "Mar")))
        try ledger.add(.transaction(makeTx(date: jan, description: "Jan")))
        try ledger.add(.transaction(makeTx(date: feb, description: "Feb")))

        // The journal itself stays in document order; the queries sort it.
        #expect(ledger.journal.transactions.map(\.description) == ["Mar", "Jan", "Feb"])
        #expect(ledger.transactions(for: "Assets:Cash").map(\.description) == ["Jan", "Feb", "Mar"])
        #expect(ledger.transactions(forPrefix: "Expenses").map(\.description) == ["Jan", "Feb", "Mar"])
        #expect(ledger.transactions().map(\.description) == ["Jan", "Feb", "Mar"])
        #expect(ledger.transactions(from: feb).map(\.description) == ["Feb", "Mar"])
    }

    @Test
    func `transactions sharing a date keep their original document order`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let jun = try makeDate(2024, 6, 1)
        try ledger.add(.transaction(makeTx(date: jun, description: "Jun")))
        for index in 1 ... 6 {
            try ledger.add(.transaction(makeTx(date: jan, description: "Jan-\(index)")))
        }

        let descriptions = ledger.transactions(for: "Assets:Cash").map(\.description)
        #expect(descriptions == ["Jan-1", "Jan-2", "Jan-3", "Jan-4", "Jan-5", "Jan-6", "Jun"])
    }

    @Test
    func `parent accounts are inferred automatically from posting names`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(
                makeTx(
                    date: date, debit: "Expenses:Food:Groceries", credit: "Assets:Checking", amount: 50,
                ),
            ),
        )
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
        try ledger.add(
            .transaction(makeTx(date: date, debit: "Suspense", credit: "Assets:Cash", amount: 100)),
        )
        let account = try #require(ledger.accounts.first { $0.name == "Suspense" })
        #expect(account.type == .asset)
    }

    @Test
    func `removeAccountDirective(named:) drops the declaration but keeps the account`() throws {
        var ledger = try Ledger(journal: JournalParser().parse("""
        account Expenses:Rent  ; declared but unused so far

        2026-03-01 Rent
            Expenses:Rent  1200.00 EUR
            Assets:Checking  -1200.00 EUR
        """))
        let directive = ledger.removeAccountDirective(named: "Expenses:Rent")
        let removed = try #require(directive)
        #expect(removed.comment == "declared but unused so far")
        #expect(ledger.accountDirective(named: "Expenses:Rent") == nil)
        // The account itself survives: its postings still name it.
        #expect(ledger.accounts.map(\.name).contains("Expenses:Rent"))
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
        #expect(
            transaction2.postings[0].amount.commodityIsPrefix
                == transaction1.postings[0].amount.commodityIsPrefix,
        )
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

    @Test
    func `a directive-only journal round-trips byte-for-byte`() throws {
        let text = """
        ; ledger-cli directives SwiftLedger does not model
        include accounts.ledger
        !include prices/2024.ledger

        P 2024-01-01 AAPL $185.00
        commodity USD
            format $1,000.00
        alias Chk=Assets:Checking
        D $1,000.00
        year 2024
        apply account Personal
            ; an indented comment
        end apply account
        """
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a comment built in code without a marker is given one`() throws {
        let journal = Journal(items: [.comment("reviewed"), .comment("; already marked")])
        let text = JournalSerializer().serialize(journal)
        #expect(text == "; reviewed\n; already marked")
        // …and the marker-less text must not come back as anything but a comment.
        #expect(try JournalParser().parse(text).items == [.comment("; reviewed"), .comment("; already marked")])
    }

    @Test
    func `a journal with every comment form round-trips byte-for-byte`() throws {
        let text = """
        ; a journal exercising every comment form SwiftLedger models
        account Expenses:Rent  ; declared but unused so far

        2026-08-14 * Day trip — outbound  ; two people
            ; paid in cash
            Expenses:Transport                              18.75 EUR
            ; TODO: split into Expenses:Misc:Fees later?
            # hash-marked comments survive too
            Assets:Checking                                 -18.75 EUR

        2026-08-15 ! (REF-1) Groceries
            Expenses:Food                                   20.5 EUR
            ; the last posting can carry a comment as well
            Assets:Cash                                     -20.5 EUR

        include other.ledger
        """
        #expect(try JournalSerializer().serialize(JournalParser().parse(text)) == text)
    }

    @Test
    func `re-serialising a non-canonical journal is stable`() throws {
        let text = "; leading note\n"
            + "account Expenses:Rent  ; declared but unused so far\n"
            + "\n"
            + "2026-08-14 * Day trip — outbound\n"
            + "\t; tab-indented, before the first posting\n"
            + "  Expenses:Transport  18.75 EUR\n"
            + "      # oddly indented, hash-marked\n"
            + "  Assets:Checking\n"
        let serializer = JournalSerializer()
        let parser = JournalParser()
        let once = try serializer.serialize(parser.parse(text))
        let twice = try serializer.serialize(parser.parse(once))
        #expect(once == twice)
        // The comment lines keep their own indentation and marker.
        #expect(once.contains("\t; tab-indented, before the first posting"))
        #expect(once.contains("      # oddly indented, hash-marked"))
    }

    @Test
    func `an in-transaction comment built in code is indented and marked`() throws {
        let transaction = try Transaction(
            date: makeDate(2026, 4, 1),
            description: "Coffee",
            postings: [
                Posting(
                    accountName: "Expenses:Food:Coffee",
                    amount: Amount(quantity: 5, commodity: "USD"),
                    trailingComments: ["reviewed"],
                ),
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: -5, commodity: "USD")),
            ],
            leadingComments: ["; no indentation"],
        )
        let text = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        let lines = text.components(separatedBy: "\n")
        #expect(lines[1] == "    ; no indentation")
        #expect(lines[3] == "    ; reviewed")
        // …and both must come back where they were, not as top-level comments.
        let reparsed = try #require(try JournalParser().parse(text).transactions.first)
        #expect(reparsed.leadingComments == ["    ; no indentation"])
        #expect(reparsed.postings[0].trailingComments == ["    ; reviewed"])
    }
}

// MARK: - JournalSerializer: leaving untouched transactions alone

@Suite("verbatim transactions") struct VerbatimTransactionTests {
    @Test
    func `a journal nobody edited serialises back byte-identical`() throws {
        let journal = try JournalParser().parse(handWrittenJournal)
        #expect(JournalSerializer().serialize(journal) == handWrittenJournal)
    }

    @Test
    func `an untouched save is idempotent, so a second one is a no-op too`() throws {
        let parser = JournalParser()
        let serializer = JournalSerializer()
        let once = try serializer.serialize(parser.parse(handWrittenJournal))
        #expect(try serializer.serialize(parser.parse(once)) == once)
    }

    @Test
    func `an elided amount is not written out when nothing edited the transaction`() throws {
        let text = try JournalSerializer().serialize(JournalParser().parse(handWrittenJournal))
        #expect(text.contains("    Income:Salary\n"))
        #expect(!text.contains("Income:Salary  "))
    }

    @Test
    func `editing one transaction reformats that one and leaves every other line alone`() throws {
        var journal = try JournalParser().parse(handWrittenJournal)
        let salary = try #require(journal.transactions.last)
        journal.remove(.transaction(salary))
        try journal.append(.transaction(Transaction(
            id: salary.id,
            date: salary.date,
            description: "Salary (adjusted)",
            postings: salary.postings,
        )))

        let written = JournalSerializer().serialize(journal).components(separatedBy: "\n")
        // Every line of the journal but the edited transaction's survives as-is.
        let untouched = handWrittenJournal.components(separatedBy: "\n")
            .filter { !$0.contains("Salary") && !$0.contains("3,000.00") }
        for line in untouched where !line.isEmpty {
            #expect(written.contains(line), "rewrote a line nobody edited: \(line)")
        }
        // The edited one, and only it, comes back canonically aligned — but
        // written the way this file writes euros. The hand-aligned column is
        // the serializer's to set and it moves; the number is the user's and
        // `3,000.00` survives, elided second leg included.
        #expect(!written.contains("    Assets:Checking          3,000.00 EUR"))
        #expect(written.contains("2024-03-01 Salary (adjusted)"))
        #expect(written.contains(where: { $0.hasPrefix("    Assets:Checking") && $0.hasSuffix("3,000.00 EUR") }))
        #expect(written.contains(where: { $0.hasPrefix("    Income:Salary") && $0.hasSuffix("-3,000.00 EUR") }))
    }

    @Test
    func `a transaction rebuilt through init drops the source text it cannot vouch for`() throws {
        let parsed = try #require(try JournalParser().parse(handWrittenJournal).transactions.first)
        #expect(parsed.sourceText != nil)
        let rebuilt = try Transaction(
            id: parsed.id,
            date: parsed.date,
            status: parsed.status,
            code: parsed.code,
            description: parsed.description,
            postings: parsed.postings,
            comment: parsed.comment,
            leadingComments: parsed.leadingComments,
        )
        #expect(rebuilt.sourceText == nil)
    }

    @Test
    func `source text is not part of the value, so removal by value still works`() throws {
        var journal = try JournalParser().parse(handWrittenJournal)
        let parsed = try #require(journal.transactions.first)
        let rebuilt = try Transaction(
            id: parsed.id,
            date: parsed.date,
            status: parsed.status,
            code: parsed.code,
            description: parsed.description,
            postings: parsed.postings,
            comment: parsed.comment,
            leadingComments: parsed.leadingComments,
        )
        #expect(rebuilt == parsed)
        #expect(Set([parsed, rebuilt]).count == 1)
        // …which is what lets a caller holding the rebuilt copy remove the parsed one.
        let removed = journal.remove(.transaction(rebuilt))
        #expect(removed)
        #expect(journal.transactions.count == 2)
    }

    @Test
    func `source text is not encoded, so a decoded transaction is formatted afresh`() throws {
        let parsed = try #require(try JournalParser().parse(handWrittenJournal).transactions.first)
        let encoded = try JSONEncoder().encode(parsed)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["sourceText"] == nil)

        let decoded = try JSONDecoder().decode(Transaction.self, from: encoded)
        #expect(decoded.sourceText == nil)
        #expect(decoded == parsed)
        // Formatted afresh in every sense: the journal it is serialised into
        // was built in code and carries no house style either, so the dollar
        // default applies and the file's `$1,234.50` is not reproduced.
        let written = JournalSerializer().serialize(Journal(items: [.transaction(decoded)]))
        #expect(written.contains("$1234.50"))
        #expect(!written.contains("$1,234.50"))
    }

    @Test
    func `a transaction built in code is formatted, having no source to fall back on`() throws {
        let transaction = try makeTx(date: makeDate(2024, 1, 1), description: "Coffee")
        #expect(transaction.sourceText == nil)
        let written = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        #expect(written.components(separatedBy: "\n")[0] == "2024-01-01 Coffee")
        #expect(written.contains("    Expenses:Food"))
    }
}

// MARK: - JournalSerializer: writing a rebuilt entry the way the file writes

/// `Decimal` forgets how a number was written — it normalises its own scale on
/// construction, and the parser strips thousands separators before it — so an
/// amount rebuilt through `Transaction.init` used to come back as whatever
/// `Decimal.description` printed: `$1,240.50` written as `$1240.5`, `@ $150.00`
/// as `@ $150`.
///
/// That was survivable while every save reformatted the whole file. Once an
/// untouched transaction started replaying its own source lines, it stopped
/// being: the reformatting landed on exactly the one entry the user edited, and
/// an edit to a payee showed up in the diff as a restyled amount.
@Suite("commodity display format") struct CommodityDisplayFormatTests {
    /// Rebuilds `transaction` with a new description, in place, the way an edit
    /// through `LedgerManager` does — through `init`, so the source text goes.
    private func renaming(
        _ transaction: Transaction,
        to description: String,
        in journal: inout Journal,
    ) throws {
        journal.remove(.transaction(transaction))
        try journal.append(.transaction(Transaction(
            id: transaction.id,
            date: transaction.date,
            auxDate: transaction.auxDate,
            status: transaction.status,
            code: transaction.code,
            description: description,
            postings: transaction.postings,
            comment: transaction.comment,
            leadingComments: transaction.leadingComments,
        )))
    }

    @Test
    func `editing the payee leaves that entry's own numbers alone`() throws {
        let text = """
        2026-08-14 * Whole Foods
            Expenses:Groceries                       $1,240.50
            Assets:Checking                         $-1,240.50
        """
        var journal = try JournalParser().parse(text)
        try renaming(#require(journal.transactions.first), to: "Whole Foods Market", in: &journal)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("$1,240.50"))
        #expect(written.contains("$-1,240.50"))
        #expect(!written.contains("$1240.5"))
        #expect(written.contains("2026-08-14 * Whole Foods Market"))
    }

    @Test
    func `a price and an assertion keep the scale the file wrote them at`() throws {
        let text = """
        2026-03-09 * Broker buy
            Assets:Brokerage:AAPL      10 AAPL @ $150.00 = 30 AAPL
            Assets:Checking          $-1,500.00
        """
        var journal = try JournalParser().parse(text)
        try renaming(#require(journal.transactions.first), to: "Broker buy (Q1)", in: &journal)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("10 AAPL @ $150.00 = 30 AAPL"))
        #expect(written.contains("$-1,500.00"))
        // The share count is not padded to match the dollars: AAPL is written
        // whole in this file, and `10.00 AAPL` would be a restyling of its own.
        #expect(!written.contains("10.00 AAPL"))
    }

    @Test
    func `a transaction built in code is written the way its journal writes`() throws {
        let text = """
        2026-01-05 * Rent
            Expenses:Rent                            $2,400.00
            Assets:Checking                         $-2,400.00
        """
        var journal = try JournalParser().parse(text)
        try journal.append(.transaction(Transaction(
            date: makeDate(2026, 1, 6),
            description: "Deposit",
            postings: [
                Posting(
                    accountName: "Assets:Checking",
                    amount: Amount(quantity: 1234.5, commodity: "$", commodityIsPrefix: true),
                ),
                Posting(
                    accountName: "Income:Salary",
                    amount: Amount(quantity: -1234.5, commodity: "$", commodityIsPrefix: false),
                ),
            ],
        )))

        // The new entry never saw the file, and `1234.5` is all its `Decimal`
        // can say — but the file writes dollars to two places with separators,
        // so that is how the entry joining it is written.
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("$1,234.50"))
        #expect(written.contains("-1,234.50 $"))
    }

    @Test
    func `with no example to learn from, only a symbol gets decimal places`() throws {
        let transaction = try Transaction(
            date: makeDate(2026, 1, 1),
            description: "Buy shares",
            postings: [
                Posting(
                    accountName: "Assets:Brokerage",
                    amount: Amount(quantity: 10, commodity: "AAPL"),
                    price: .perUnit(Amount(quantity: 150, commodity: "$", commodityIsPrefix: true)),
                ),
                Posting(
                    accountName: "Assets:Checking",
                    amount: Amount(quantity: -1500, commodity: "$", commodityIsPrefix: true),
                ),
            ],
        )
        let written = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        // `$` is a currency however little the file says; `AAPL` is spelled the
        // way `USD` is and could be either, so it is left as written.
        #expect(written.contains("10 AAPL @ $150.00"))
        #expect(written.contains("-$1500.00"))
    }

    @Test
    func `the house style is a floor, so an odd amount keeps every digit`() throws {
        let text = """
        2026-01-05 * Rent
            Expenses:Rent                             $2,400.00
            Assets:Checking                          -$2,400.00

        2026-01-20 * Groceries
            Expenses:Groceries                           $60.00
            Assets:Checking                             -$60.00

        2026-02-01 * Interest
            Expenses:Fees                                 $0.333
            Assets:Checking                              -$0.333
        """
        var journal = try JournalParser().parse(text)
        try renaming(#require(journal.transactions.last), to: "Interest (revised)", in: &journal)

        // Two decimals is this file's style — one odd amount is an odd amount,
        // not a house style — but rounding to it would change what the journal
        // says and leave the entry no longer balancing.
        let written = JournalSerializer().serialize(journal)
        #expect(journal.commodityFormats["$"]?.fractionDigits == 2)
        #expect(written.contains("$0.333"))
        #expect(written.contains("-$0.333"))
    }

    @Test
    func `the minus sign goes back on the side of the symbol the file puts it`() throws {
        let text = """
        2026-02-01 * Rent
            Expenses:Rent                             $2,400.00
            Assets:Checking                           $-2,400.00
        """
        var journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["$"]?.signPrecedesCommodity == false)
        try renaming(#require(journal.transactions.first), to: "Rent (Feb)", in: &journal)

        // `$-2,400.00` and `-$2,400.00` mean the same thing and the parser
        // reads both, which is exactly why swapping one for the other is a
        // change the user did not ask for.
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("$-2,400.00"))
        #expect(!written.contains("-$2,400.00"))
    }

    @Test
    func `a file that writes no separators is not given any`() throws {
        let text = """
        2026-02-01 * Rent
            Expenses:Rent                            3000.00 EUR
            Assets:Checking                         -3000.00 EUR
        """
        var journal = try JournalParser().parse(text)
        try renaming(#require(journal.transactions.first), to: "Rent (Feb)", in: &journal)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("3000.00 EUR"))
        #expect(!written.contains("3,000.00 EUR"))
    }

    @Test
    func `formats survive the remove-and-append an edit is made of`() throws {
        var journal = try JournalParser().parse(handWrittenJournal)
        #expect(journal.commodityFormats["$"] == CommodityFormat(
            fractionDigits: 2,
            groupsThousands: true,
            signPrecedesCommodity: false,
        ))
        #expect(journal.commodityFormats["AAPL"] == CommodityFormat(fractionDigits: 0, groupsThousands: false))

        try renaming(#require(journal.transactions.first), to: "Groceries (revised)", in: &journal)
        #expect(journal.commodityFormats["$"]?.fractionDigits == 2)
    }

    @Test
    func `a rewritten entry is stable, so the next save changes nothing`() throws {
        let parser = JournalParser()
        let serializer = JournalSerializer()
        var journal = try parser.parse(handWrittenJournal)
        try renaming(#require(journal.transactions.first), to: "Groceries (revised)", in: &journal)

        let once = serializer.serialize(journal)
        #expect(try serializer.serialize(parser.parse(once)) == once)
    }

    @Test
    func `the style describes the file, so it is not encoded with the journal`() throws {
        let journal = try JournalParser().parse(handWrittenJournal)
        #expect(!journal.commodityFormats.isEmpty)

        let encoded = try JSONEncoder().encode(journal)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["commodityFormats"] == nil)
        #expect(try JSONDecoder().decode(Journal.self, from: encoded).commodityFormats.isEmpty)
    }

    @Test
    func `a D directive settles the style the amounts alone would not`() throws {
        let text = """
        D $1,000.00

        2026-02-01 * Rent
            Expenses:Rent      $2400
            Assets:Checking    $-2400
        """
        var journal = try JournalParser().parse(text)
        // Left to the postings, this file writes dollars whole and ungrouped.
        // The directive says otherwise, and it is the user saying it.
        #expect(journal.commodityFormats["$"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["$"]?.groupsThousands == true)

        try renaming(#require(journal.transactions.first), to: "Rent (Feb)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("$2,400.00"))
        #expect(written.contains("$-2,400.00"))
        // …and the directive line is still the line the user wrote.
        #expect(written.contains("D $1,000.00"))
    }

    @Test
    func `a format line inside a commodity block says the same thing`() throws {
        let text = """
        commodity $
            format $1,000.00
            note US dollars

        2026-02-01 * Rent
            Expenses:Rent      $2400
            Assets:Checking    $-2400
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["$"] == CommodityFormat(
            fractionDigits: 2,
            groupsThousands: true,
            signPrecedesCommodity: false,
        ))
        // Reading a line is not modelling it: every one of them still goes
        // back exactly as written.
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a commodity directive naming a symbol alone states no style`() throws {
        let text = """
        commodity $

        2026-02-01 * Rent
            Expenses:Rent      $2400
            Assets:Checking    $-2400
        """
        var journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["$"]?.fractionDigits == 0)

        try renaming(#require(journal.transactions.first), to: "Rent (Feb)", in: &journal)
        #expect(JournalSerializer().serialize(journal).contains("$-2400"))
    }

    @Test
    func `rendering pads and groups without touching the value`() throws {
        let money = CommodityFormat(fractionDigits: 2, groupsThousands: true)
        #expect(try money.render(#require(Decimal(string: "1234567.5"))) == "1,234,567.50")
        #expect(money.render(1000) == "1,000.00")
        #expect(money.render(999) == "999.00")
        #expect(try money.render(#require(Decimal(string: "0.12345"))) == "0.12345")

        let plain = CommodityFormat()
        #expect(try plain.render(#require(Decimal(string: "1234567.5"))) == "1234567.5")
        #expect(plain.render(10) == "10")
    }
}

// MARK: - Codable

@Suite("Codable") struct CodableTests {
    @Test
    func `a posting encoded before trailingComments existed still decodes`() throws {
        let json = """
        {"accountName":"Assets:Cash",
         "amount":{"quantity":5,"commodity":"USD","commodityIsPrefix":false}}
        """
        let posting = try JSONDecoder().decode(Posting.self, from: Data(json.utf8))
        #expect(posting.accountName == "Assets:Cash")
        #expect(posting.trailingComments.isEmpty)
    }

    @Test
    func `a transaction encoded before leadingComments existed still decodes`() throws {
        let transaction = try makeTx(date: makeDate(2026, 5, 1))
        let encoded = try JSONEncoder().encode(transaction)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "leadingComments")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Transaction.self, from: legacy)
        #expect(decoded.id == transaction.id)
        #expect(decoded.postings == transaction.postings)
        #expect(decoded.leadingComments.isEmpty)
    }

    @Test
    func `an account directive encoded before comment existed still decodes`() throws {
        let json = #"{"name":"Assets:Cash"}"#
        let directive = try JSONDecoder().decode(AccountDirective.self, from: Data(json.utf8))
        #expect(directive.name == "Assets:Cash")
        #expect(directive.comment == nil)
    }

    @Test
    func `a posting encoded before price and balanceAssertion existed still decodes`() throws {
        let json = """
        {"accountName":"Assets:Cash",
         "amount":{"quantity":5,"commodity":"USD","commodityIsPrefix":false}}
        """
        let posting = try JSONDecoder().decode(Posting.self, from: Data(json.utf8))
        #expect(posting.price == nil)
        #expect(posting.balanceAssertion == nil)
        #expect(posting.balancingAmount == posting.amount)
    }

    @Test
    func `a round-tripped posting keeps its price and balance assertion`() throws {
        let posting = Posting(
            accountName: "Assets:Brokerage",
            amount: Amount(quantity: 10, commodity: "AAPL"),
            price: .total(Amount(quantity: 1500, commodity: "$", commodityIsPrefix: true)),
            balanceAssertion: Amount(quantity: 30, commodity: "AAPL"),
        )
        let decoded = try JSONDecoder().decode(Posting.self, from: JSONEncoder().encode(posting))
        #expect(decoded == posting)
        #expect(decoded.balancingAmount.quantity == 1500)
    }

    @Test
    func `a round-tripped posting keeps its trailing comments`() throws {
        let posting = Posting(
            accountName: "Expenses:Transport",
            amount: Amount(quantity: 47, commodity: "EUR"),
            trailingComments: ["    ; needs a category"],
        )
        let decoded = try JSONDecoder().decode(Posting.self, from: JSONEncoder().encode(posting))
        #expect(decoded == posting)
    }

    @Test
    func `a round-tripped balance matrix keeps its rows and answers lookups`() throws {
        let matrix = try makeMatrixLedger().balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        let decoded = try JSONDecoder().decode(
            BalanceMatrix.self, from: JSONEncoder().encode(matrix),
        )
        #expect(decoded == matrix)
        #expect(decoded.accountNames == matrix.accountNames)
        #expect(decoded["Assets:Checking"]?.endingBalance() == [usd(3950)])
    }

    @Test
    func `a balance matrix decoded with its rows out of order still looks them up`() throws {
        // `subscript(_:)` binary-searches, so decoding has to restore the
        // ordering rather than trust whatever wrote the JSON.
        let json = """
        {"bucketStarts": [{"year": 2024, "month": 1, "day": 1}],
         "to": {"year": 2024, "month": 1, "day": 31},
         "rows": [
           {"account": {"name": "Zebra", "type": "unclassified"},
            "opening": [], "changes": [[]]},
           {"account": {"name": "Assets:Cash", "type": "asset"},
            "opening": [], "changes": [[]]}]}
        """
        let matrix = try JSONDecoder().decode(BalanceMatrix.self, from: Data(json.utf8))
        #expect(matrix.accountNames == ["Assets:Cash", "Zebra"])
        #expect(matrix["Assets:Cash"]?.account.name == "Assets:Cash")
        #expect(matrix["Zebra"]?.account.name == "Zebra")
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

        let transaction = try #require(
            try PlainTextJournalStore(url: url).load().journal.transactions.first,
        )
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
        try ledger.add(
            .transaction(
                Transaction(
                    date: makeDate(2024, 6, 1), description: "Coffee",
                    postings: [
                        Posting(
                            accountName: "Expenses:Food",
                            amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true),
                        ),
                        Posting(
                            accountName: "Assets:Cash",
                            amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true),
                        ),
                    ],
                ),
            ),
        )
        try store.save(ledger)

        let reloaded = try store.load()
        #expect(reloaded.journal.transactions.count == 2)
        let coffee = try #require(reloaded.journal.transactions.first { $0.description == "Coffee" })
        #expect(coffee.postings[0].amount.quantity == 5)
        #expect(coffee.postings[0].amount.commodity == "$")
    }

    @Test
    func `saving a multi-file journal leaves its include directives intact`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }

        try """
        include accounts.ledger
        include 2023.ledger
        P 2024-01-01 AAPL $185.00

        2024-01-01 Opening
            Assets:Cash     1000 USD
            Equity:Opening  -1000 USD
        """.write(to: url, atomically: true, encoding: .utf8)

        let store = PlainTextJournalStore(url: url)
        var ledger = try store.load()
        try ledger.add(
            .transaction(
                Transaction(
                    date: makeDate(2024, 6, 1), description: "Coffee",
                    postings: [
                        Posting(accountName: "Expenses:Food", amount: Amount(quantity: 5, commodity: "USD")),
                        Posting(accountName: "Assets:Cash", amount: Amount(quantity: -5, commodity: "USD")),
                    ],
                ),
            ),
        )
        try store.save(ledger)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("include accounts.ledger"))
        #expect(written.contains("include 2023.ledger"))
        #expect(written.contains("P 2024-01-01 AAPL $185.00"))
        #expect(!written.contains("; include"))
        #expect(try store.load().journal.transactions.count == 2)
    }
}

// MARK: - BalanceSheet

@Suite("BalanceSheet") struct BalanceSheetTests {
    @Test
    func `any well-formed double-entry journal satisfies isBalanced`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(
                makeTx(
                    date: date, description: "Salary", debit: "Assets:Checking",
                    credit: "Income:Salary", amount: 3000, commodity: "USD",
                ),
            ),
        )
        #expect(BalanceSheet(ledger: ledger).isBalanced)
    }

    @Test
    func `asset account balance matches its posting amounts`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(
                makeTx(
                    date: date, description: "Salary", debit: "Assets:Checking",
                    credit: "Income:Salary", amount: 3000, commodity: "USD",
                ),
            ),
        )
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
        try ledger.add(
            .transaction(
                Transaction(
                    date: date, description: "Salary",
                    postings: [
                        Posting(
                            accountName: "Assets:Checking", amount: Amount(quantity: 3000, commodity: "USD"),
                        ),
                        Posting(
                            accountName: "Income:Salary", amount: Amount(quantity: -3000, commodity: "USD"),
                        ),
                    ],
                ),
            ),
        )
        try ledger.add(
            .transaction(
                Transaction(
                    date: date, description: "Rent",
                    postings: [
                        Posting(accountName: "Expenses:Rent", amount: Amount(quantity: 1000, commodity: "USD")),
                        Posting(
                            accountName: "Assets:Checking", amount: Amount(quantity: -1000, commodity: "USD"),
                        ),
                    ],
                ),
            ),
        )
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
    func `same-date lines follow document order with a running balance after each posting`() throws {
        var ledger = Ledger()
        let date = try makeDate(2024, 1, 1)
        try ledger.add(
            .transaction(
                Transaction(
                    date: date, description: "Deposit",
                    postings: [
                        Posting(
                            accountName: "Assets:Checking", amount: Amount(quantity: 1000, commodity: "USD"),
                        ),
                        Posting(
                            accountName: "Equity:Opening", amount: Amount(quantity: -1000, commodity: "USD"),
                        ),
                    ],
                ),
            ),
        )
        try ledger.add(
            .transaction(
                Transaction(
                    date: date, description: "Coffee",
                    postings: [
                        Posting(accountName: "Expenses:Food", amount: Amount(quantity: 5, commodity: "USD")),
                        Posting(accountName: "Assets:Checking", amount: Amount(quantity: -5, commodity: "USD")),
                    ],
                ),
            ),
        )
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
        try ledger.add(
            .transaction(
                Transaction(
                    date: jan, description: "Jan",
                    postings: [
                        Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                        Posting(accountName: "Income:A", amount: Amount(quantity: -100, commodity: "USD")),
                    ],
                ),
            ),
        )
        try ledger.add(
            .transaction(
                Transaction(
                    date: jun, description: "Jun",
                    postings: [
                        Posting(accountName: "Assets:Cash", amount: Amount(quantity: 200, commodity: "USD")),
                        Posting(accountName: "Income:A", amount: Amount(quantity: -200, commodity: "USD")),
                    ],
                ),
            ),
        )
        let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Cash", to: mar)
        #expect(stmt.lines.count == 1)
        #expect(stmt.lines[0].transaction.description == "Jan")
    }

    @Test
    func `lines are chronological with a correct running balance when the journal is out of order`() throws {
        var ledger = Ledger()
        let jan = try makeDate(2024, 1, 1)
        let feb = try makeDate(2024, 2, 1)
        let mar = try makeDate(2024, 3, 1)
        let coffee = try makeTx(
            date: mar, description: "Coffee", debit: "Expenses:Food", credit: "Assets:Checking", amount: 5,
        )
        let deposit = try makeTx(
            date: jan, description: "Deposit", debit: "Assets:Checking", credit: "Equity:Opening",
            amount: 1000,
        )
        let rent = try makeTx(
            date: feb, description: "Rent", debit: "Expenses:Housing", credit: "Assets:Checking",
            amount: 200,
        )
        let fee = try makeTx(
            date: feb, description: "Fee", debit: "Expenses:Bank", credit: "Assets:Checking", amount: 10,
        )
        // Written out of date order, with Rent and Fee sharing February.
        for transaction in [coffee, deposit, rent, fee] {
            ledger.add(.transaction(transaction))
        }

        let stmt = AccountStatement(ledger: ledger, accountName: "Assets:Checking")
        #expect(stmt.lines.map(\.transaction.description) == ["Deposit", "Rent", "Fee", "Coffee"])
        let balances = stmt.lines.map { $0.runningBalance[0].quantity }
        #expect(balances == [1000, 800, 790, 785])
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

    @Test
    func `removeAccountDirective(named:) returns the directive and persists once`() throws {
        let store = MockLedgerStore()
        let manager = try LedgerManager(store: store)
        try manager.add(.accountDirective(AccountDirective(name: "Expenses:Rent", comment: "unused")))
        #expect(store.saveCallCount == 1)
        let removed = try #require(try manager.removeAccountDirective(named: "Expenses:Rent"))
        #expect(removed.comment == "unused")
        #expect(store.saveCallCount == 2)
        #expect(manager.accountDirective(named: "Expenses:Rent") == nil)
    }

    @Test
    func `removeAccountDirective(named:) returns nil and does not save when undeclared`() throws {
        let store = MockLedgerStore()
        let manager = try LedgerManager(store: store)
        #expect(try manager.removeAccountDirective(named: "Expenses:Rent") == nil)
        #expect(store.saveCallCount == 0)
    }

    @Test
    func `removeAccountDirective(named:) keeps the directive when save throws`() throws {
        let store = MockLedgerStore()
        let manager = try LedgerManager(store: store)
        try manager.add(.accountDirective(AccountDirective(name: "Expenses:Rent", comment: "unused")))
        store.saveError = CocoaError(.fileWriteOutOfSpace)
        #expect(throws: CocoaError.self) { try manager.removeAccountDirective(named: "Expenses:Rent") }
        store.saveError = nil
        // The failed removal left the declaration in place, so a retry finds it.
        #expect(try manager.removeAccountDirective(named: "Expenses:Rent")?.comment == "unused")
    }

    @Test
    func `add leaves ledger unchanged when save throws, so retry writes a single copy`() throws {
        let store = MockLedgerStore()
        let manager = try LedgerManager(store: store)
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "Salary",
            postings: [
                Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                Posting(accountName: "Income:Salary", amount: Amount(quantity: -100, commodity: "USD")),
            ],
        )
        store.saveError = CocoaError(.fileWriteOutOfSpace)
        #expect(throws: CocoaError.self) { try manager.add(.transaction(transaction)) }
        #expect(manager.transactions(for: "Assets:Cash").isEmpty)

        store.saveError = nil
        try manager.add(.transaction(transaction))
        #expect(manager.transactions(for: "Assets:Cash").count == 1)
    }
}

// MARK: - Series queries

@Suite("SeriesQueries") struct SeriesQueriesTests {
    private func makeLedger() throws -> Ledger {
        var ledger = Ledger()
        // Pre-window history, in-window activity with gaps, multi-commodity.
        try ledger.add(.transaction(makeTx(date: makeDate(2024, 1, 10), amount: 100)))
        try ledger.add(.transaction(makeTx(date: makeDate(2024, 3, 2), amount: 25)))
        try ledger.add(.transaction(makeTx(date: makeDate(2024, 3, 2), amount: 5)))
        try ledger.add(.transaction(makeTx(date: makeDate(2024, 3, 5), amount: 40, commodity: "EUR")))
        try ledger.add(
            .transaction(
                makeTx(
                    date: makeDate(2024, 4, 1), description: "Salary",
                    debit: "Assets:Cash", credit: "Income:Salary", amount: 500,
                ),
            ),
        )
        return ledger
    }

    @Test
    func `subtreeBalanceSeries matches per-day subtreeBalance across the window`() throws {
        let ledger = try makeLedger()
        let from = try makeDate(2024, 3, 1)
        let windowEnd = try makeDate(2024, 4, 3)
        let series = ledger.subtreeBalanceSeries(forPrefix: "Assets", from: from, to: windowEnd)

        let calendar = Calendar(identifier: .gregorian)
        let dayCount =
            (calendar.dateComponents([.day], from: from.date(), to: windowEnd.date()).day ?? 0) + 1
        #expect(series.count == dayCount)

        for offset in 0 ..< dayCount {
            let day = try JournalDate(#require(calendar.date(byAdding: .day, value: offset, to: from.date())))
            let expected = ledger.subtreeBalance(forPrefix: "Assets", asOf: day)
                .sorted { $0.commodity < $1.commodity }
            #expect(series[offset] == expected, "mismatch at \(day)")
        }
    }

    @Test
    func `subtreeBalanceSeries is empty when from is after to`() throws {
        let ledger = try makeLedger()
        let series = try ledger.subtreeBalanceSeries(
            forPrefix: "Assets", from: makeDate(2024, 4, 3), to: makeDate(2024, 3, 1),
        )
        #expect(series.isEmpty)
    }

    @Test
    func `incomeStatementSeries matches per-bucket IncomeStatement totals`() throws {
        let ledger = try makeLedger()
        let starts = try [makeDate(2024, 1, 1), makeDate(2024, 3, 1), makeDate(2024, 4, 1)]
        let windowEnd = try makeDate(2024, 4, 30)
        let series = ledger.incomeStatementSeries(bucketStarts: starts, to: windowEnd)
        #expect(series.count == starts.count)

        for (index, bucket) in series.enumerated() {
            let bucketTo: JournalDate
            if index + 1 < starts.count {
                let next = starts[index + 1].date()
                let calendar = Calendar(identifier: .gregorian)
                bucketTo = try JournalDate(#require(calendar.date(byAdding: .day, value: -1, to: next)))
            } else {
                bucketTo = windowEnd
            }
            let statement = IncomeStatement(ledger: ledger, from: starts[index], to: bucketTo)
            let expectedRevenues = statement.revenues.flatMap(\.amounts).netByCommodity()
                .filter { !$0.isZero }
            let expectedExpenses = statement.expenses.flatMap(\.amounts).netByCommodity()
                .filter { !$0.isZero }
            #expect(bucket.revenues == expectedRevenues, "revenues mismatch in bucket \(index)")
            #expect(bucket.expenses == expectedExpenses, "expenses mismatch in bucket \(index)")
        }
    }

    @Test
    func `incomeStatementSeries assigns bucket-start-day transactions to that bucket`() throws {
        var ledger = Ledger()
        try ledger.add(
            .transaction(
                makeTx(
                    date: makeDate(2024, 2, 1), description: "OnBoundary",
                    debit: "Expenses:Rent", credit: "Assets:Cash", amount: 900,
                ),
            ),
        )
        let series = try ledger.incomeStatementSeries(
            bucketStarts: [makeDate(2024, 1, 1), makeDate(2024, 2, 1)],
            to: makeDate(2024, 2, 28),
        )
        #expect(series[0].expenses.isEmpty)
        #expect(series[1].expenses == [Amount(quantity: 900, commodity: "USD")])
    }
}

// MARK: - Balance matrix

/// The day before `date`, in the Gregorian calendar.
private func dayBefore(_ date: JournalDate) throws -> JournalDate {
    let calendar = Calendar(identifier: .gregorian)
    return try JournalDate(#require(calendar.date(byAdding: .day, value: -1, to: date.date())))
}

private func usd(_ quantity: Decimal) -> Amount {
    Amount(quantity: quantity, commodity: "USD")
}

private func eur(_ quantity: Decimal) -> Amount {
    Amount(quantity: quantity, commodity: "EUR")
}

/// Pre-window history, multi-commodity activity, a cleared/unmarked mix, an
/// account reachable only through one description, a bucket whose postings
/// cancel out, an out-of-window transaction — and deliberately **not** in
/// date order, so every case built on it also exercises document order.
private func makeMatrixLedger() throws -> Ledger {
    try Ledger(journal: JournalParser().parse("""
    2024-02-14 * Groceries
        Expenses:Food                    30 USD
        Assets:Checking                 -30 USD

    2023-12-15 Opening balance
        Assets:Checking                1000 USD
        Equity:Opening                -1000 USD

    2024-05-01 After the window
        Expenses:Food                   999 USD
        Assets:Checking                -999 USD

    2024-01-05 Groceries
        Expenses:Food                    50 USD
        Assets:Checking                 -50 USD

    2024-03-03 * Grocery refund
        Expenses:Food                   -30 USD
        Assets:Checking                  30 USD

    2024-01-20 * Salary
        Assets:Checking                3000 USD
        Income:Salary                 -3000 USD

    2024-02-10 Travel to Berlin
        Expenses:Travel                  40 EUR
        Assets:Cash                     -40 EUR

    2024-02-20 Snacks
        Expenses:Food                    20 USD
        Assets:Cash                     -20 USD

    2024-03-10 Misc outlay
        Expenses:Misc                    12 USD
        Assets:Cash                     -12 USD

    2024-03-11 Misc refunded
        Expenses:Misc                   -12 USD
        Assets:Cash                      12 USD
    """))
}

/// The three monthly buckets the fixture is usually read through:
/// January, February and March 2024.
private func monthlyStarts() throws -> [JournalDate] {
    try [makeDate(2024, 1, 1), makeDate(2024, 2, 1), makeDate(2024, 3, 1)]
}

@Suite("BalanceMatrix cross-checks") struct BalanceMatrixCrossCheckTests {
    @Test
    func `opening plus cumulative changes matches balance(for:asOf:) at each boundary`() throws {
        let ledger = try makeMatrixLedger()
        let starts = try monthlyStarts()
        let windowEnd = try makeDate(2024, 3, 31)
        let matrix = ledger.balanceMatrix(bucketStarts: starts, to: windowEnd)

        var boundaries: [JournalDate] = []
        for index in starts.indices {
            try boundaries.append(
                index + 1 < starts.count ? dayBefore(starts[index + 1]) : windowEnd,
            )
        }

        for row in matrix.rows {
            let endings = row.endingBalances()
            #expect(endings.count == starts.count)
            for (index, boundary) in boundaries.enumerated() {
                let expected = ledger.balance(for: row.account.name, asOf: boundary)
                #expect(
                    endings[index] == expected,
                    "\(row.account.name) at \(boundary): \(endings[index]) != \(expected)",
                )
            }
        }
        // Every account named by a posting on or before the window end has a row.
        #expect(matrix.accountNames == [
            "Assets:Cash", "Assets:Checking", "Equity:Opening",
            "Expenses:Food", "Expenses:Misc", "Expenses:Travel", "Income:Salary",
        ])
    }

    @Test
    func `a single-bucket matrix agrees with IncomeStatement revenues and expenses`() throws {
        let ledger = try makeMatrixLedger()

        func check(from: JournalDate, to windowEnd: JournalDate) {
            let matrix = ledger.balanceMatrix(bucketStarts: [from], to: windowEnd)
            let statement = IncomeStatement(ledger: ledger, from: from, to: windowEnd)

            func entries(_ type: AccountType) -> [(name: String, amounts: [Amount])] {
                matrix.rows
                    .filter { $0.account.type == type }
                    .compactMap { row in
                        let amounts = row.changes[0].filter { !$0.isZero }
                        return amounts.isEmpty ? nil : (row.account.name, amounts)
                    }
            }

            let expected = [
                (AccountType.revenue, statement.revenues),
                (AccountType.expense, statement.expenses),
            ]
            for (type, balances) in expected {
                let actual = entries(type)
                #expect(
                    actual.map(\.name) == balances.map(\.account.name),
                    "\(type) accounts from \(from)",
                )
                #expect(
                    actual.map(\.amounts) == balances.map(\.amounts),
                    "\(type) amounts from \(from)",
                )
            }
        }

        try check(from: makeDate(2024, 1, 1), to: makeDate(2024, 3, 31))
        // March alone: one non-zero expense, one that cancels out, and a
        // revenue account with no activity at all — each dropped or kept
        // the same way on both sides.
        try check(from: makeDate(2024, 3, 1), to: makeDate(2024, 3, 31))
    }

    @Test
    func `per-day buckets aggregate to subtreeBalanceSeries`() throws {
        let ledger = try makeMatrixLedger()
        let from = try makeDate(2024, 1, 1)
        let windowEnd = try makeDate(2024, 3, 31)

        let calendar = Calendar(identifier: .gregorian)
        let dayCount =
            (calendar.dateComponents([.day], from: from.date(), to: windowEnd.date()).day ?? 0) + 1
        var days: [JournalDate] = []
        for offset in 0 ..< dayCount {
            let day = calendar.date(byAdding: .day, value: offset, to: from.date())
            try days.append(JournalDate(#require(day)))
        }

        let matrix = ledger.balanceMatrix(bucketStarts: days, to: windowEnd)
        for prefix in ["Assets", "Expenses", "Assets:Cash"] {
            let series = ledger.subtreeBalanceSeries(forPrefix: prefix, from: from, to: windowEnd)
            let endings = matrix.rows
                .filter { $0.account.name == prefix || $0.account.name.hasPrefix(prefix + ":") }
                .map { $0.endingBalances() }
            for day in 0 ..< dayCount {
                let aggregated = endings.flatMap { $0[day] }.netByCommodity()
                #expect(aggregated == series[day], "\(prefix) on \(days[day])")
            }
        }
    }
}

@Suite("BalanceMatrix bucketing") struct BalanceMatrixBucketingTests {
    @Test
    func `bucket assignment follows dates, not document order`() throws {
        let ledger = try makeMatrixLedger()
        // The fixture is stored out of date order…
        let dates = ledger.journal.transactions.map(\.date)
        #expect(try dates.first == makeDate(2024, 2, 14))
        #expect(dates != dates.sorted())

        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        let checking = try #require(matrix["Assets:Checking"])
        #expect(checking.opening == [usd(1000)])
        #expect(checking.changes == [[usd(2950)], [usd(-30)], [usd(30)]])
        #expect(checking.endingBalances() == [[usd(3950)], [usd(3920)], [usd(3950)]])
        #expect(checking.endingBalance() == [usd(3950)])
    }

    @Test
    func `a transaction dated on a bucket start belongs to that bucket`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 2, 1), makeDate(2024, 3, 3)],
            to: makeDate(2024, 3, 31),
        )
        // The 2024-03-03 refund opens the second bucket rather than closing the first.
        #expect(matrix["Expenses:Food"]?.changes == [[usd(50)], [usd(-30)]])
    }

    @Test
    func `single-day buckets separate consecutive days`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 3, 10), makeDate(2024, 3, 11)],
            to: makeDate(2024, 3, 11),
        )
        let misc = try #require(matrix["Expenses:Misc"])
        #expect(misc.opening.isEmpty)
        #expect(misc.changes == [[usd(12)], [usd(-12)]])
    }

    @Test
    func `transactions after the window end land nowhere`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        let food = try #require(matrix["Expenses:Food"])
        // The 999 USD entry on 2024-05-01 reaches neither opening nor any bucket…
        #expect(food.opening.isEmpty)
        #expect(food.endingBalance() == [usd(70)])
        // …though the ledger itself still holds it.
        #expect(ledger.balance(for: "Expenses:Food") == [usd(1069)])
    }

    @Test
    func `bucketStarts beginning after the window end leave every posting in opening`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 6, 1)], to: makeDate(2024, 3, 31),
        )
        let checking = try #require(matrix["Assets:Checking"])
        #expect(checking.opening == [usd(3950)])
        #expect(checking.changes == [[]])
    }

    @Test
    func `empty bucketStarts yields an empty matrix`() throws {
        let ledger = try makeMatrixLedger()
        let windowEnd = try makeDate(2024, 3, 31)
        let matrix = ledger.balanceMatrix(bucketStarts: [], to: windowEnd)
        #expect(matrix.rows.isEmpty)
        #expect(matrix.bucketStarts.isEmpty)
        #expect(matrix.bucketCount == 0)
        #expect(matrix.to == windowEnd)
        #expect(matrix["Assets:Checking"] == nil)
    }
}

@Suite("BalanceMatrix zeros, commodities and rows") struct BalanceMatrixRowTests {
    @Test
    func `a bucket that cancels out keeps a zero while an empty bucket stays empty`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        let misc = try #require(matrix["Expenses:Misc"])
        // March holds +12 and -12; January and February hold nothing at all.
        #expect(misc.changes == [[], [], [usd(0)]])
        #expect(misc.endingBalances() == [[], [], [usd(0)]])
    }

    @Test
    func `mixed commodities in one account net separately and sort by commodity`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        let cash = try #require(matrix["Assets:Cash"])
        #expect(cash.changes == [[], [eur(-40), usd(-20)], [usd(0)]])
        #expect(cash.endingBalance() == [eur(-40), usd(-20)])
    }

    @Test
    func `rows are exact posting accounts with no parent roll-up`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        #expect(matrix["Expenses"] == nil)
        #expect(matrix["Assets"] == nil)
        #expect(matrix["Nothing:Here"] == nil)
        #expect(matrix.accountNames == matrix.accountNames.sorted())
        #expect(matrix.rows.allSatisfy { $0.changes.count == matrix.bucketCount })
    }

    @Test
    func `an account directive type overrides name-based inference on a row`() throws {
        var ledger = Ledger()
        ledger.add(.accountDirective(AccountDirective(name: "Suspense", type: .asset)))
        try ledger.add(
            .transaction(
                makeTx(date: makeDate(2024, 1, 5), debit: "Suspense", credit: "Assets:Cash"),
            ),
        )
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 1, 1)], to: makeDate(2024, 1, 31),
        )
        #expect(matrix["Suspense"]?.account.type == .asset)
    }

    @Test
    func `the initialiser sorts rows, whatever order they are handed in`() throws {
        let rows = [
            BalanceMatrix.Row(account: Account(name: "Zebra"), opening: [], changes: [[]]),
            BalanceMatrix.Row(account: Account(name: "Assets:Cash"), opening: [], changes: [[]]),
        ]
        let matrix = try BalanceMatrix(
            bucketStarts: [makeDate(2024, 1, 1)], to: makeDate(2024, 1, 31), rows: rows,
        )
        #expect(matrix.accountNames == ["Assets:Cash", "Zebra"])
        // Unsorted rows would leave the binary search missing both of them.
        #expect(matrix["Assets:Cash"]?.account.name == "Assets:Cash")
        #expect(matrix["Zebra"]?.account.name == "Zebra")
    }

    @Test
    func `balanceMatrix is re-exposed on LedgerManager`() throws {
        let manager = try LedgerManager(store: InMemoryLedgerStore(ledger: makeMatrixLedger()))
        let matrix = try manager.balanceMatrix(
            bucketStarts: monthlyStarts(), to: makeDate(2024, 3, 31),
        )
        #expect(matrix["Assets:Checking"]?.endingBalance() == [usd(3950)])
    }
}

@Suite("BalanceMatrix including predicate") struct BalanceMatrixPredicateTests {
    @Test
    func `a status predicate keeps excluded transactions out of opening and every bucket`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 1, 1)],
            to: makeDate(2024, 3, 31),
            including: { $0.status == .cleared },
        )
        // Only the three `*` transactions survive, and the unmarked
        // 2023-12-15 opening balance is gone from `opening` as well.
        #expect(matrix.accountNames == ["Assets:Checking", "Expenses:Food", "Income:Salary"])
        let checking = try #require(matrix["Assets:Checking"])
        #expect(checking.opening.isEmpty)
        #expect(checking.changes == [[usd(3000)]])
        // 30 in, 30 straight back out — kept as an explicit zero, not dropped.
        #expect(matrix["Expenses:Food"]?.changes == [[usd(0)]])
        #expect(matrix["Income:Salary"]?.changes == [[usd(-3000)]])
    }

    @Test
    func `an account seen only through excluded transactions gets no row`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(),
            to: makeDate(2024, 3, 31),
            including: { !$0.description.contains("Travel") },
        )
        // Expenses:Travel is named by that one transaction alone.
        #expect(matrix["Expenses:Travel"] == nil)
        #expect(!matrix.accountNames.contains("Expenses:Travel"))
        // Assets:Cash survives, without the EUR leg it shared with Travel.
        #expect(matrix["Assets:Cash"]?.changes == [[], [usd(-20)], [usd(0)]])
    }

    @Test
    func `the predicate sees whole transactions, so every posting of a kept one counts`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: [makeDate(2024, 1, 1)],
            to: makeDate(2024, 3, 31),
            including: { $0.description == "Salary" },
        )
        // Matching the transaction's description pulls in its
        // Assets:Checking leg too, not just Income:Salary.
        #expect(matrix.accountNames == ["Assets:Checking", "Income:Salary"])
        #expect(matrix["Assets:Checking"]?.changes == [[usd(3000)]])
    }

    @Test
    func `a nil predicate matches passing one that accepts everything`() throws {
        let ledger = try makeMatrixLedger()
        let starts = try monthlyStarts()
        let windowEnd = try makeDate(2024, 3, 31)
        #expect(
            ledger.balanceMatrix(bucketStarts: starts, to: windowEnd)
                == ledger.balanceMatrix(
                    bucketStarts: starts, to: windowEnd, including: { _ in true },
                ),
        )
    }

    @Test
    func `a predicate that rejects everything yields no rows`() throws {
        let ledger = try makeMatrixLedger()
        let matrix = try ledger.balanceMatrix(
            bucketStarts: monthlyStarts(),
            to: makeDate(2024, 3, 31),
            including: { _ in false },
        )
        #expect(matrix.rows.isEmpty)
        #expect(matrix.bucketCount == 3)
    }
}

// MARK: - Test doubles

private final class MockLedgerStore: LedgerStore {
    private(set) var saveCallCount = 0
    var saveError: Error?
    func load() throws -> Ledger {
        Ledger()
    }

    func save(_: Ledger) throws {
        if let saveError { throw saveError }
        saveCallCount += 1
    }
}
