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

/// One of the fields a journal has to write on a single line, with the path
/// `LedgerError.lineBreakInField` reports it under. A parameterised test walks
/// every case, so a field that gains a line of its own and no check shows up
/// here as a case nobody wrote.
enum OneLineField: CaseIterable {
    case description
    case code
    case comment
    case leadingComment
    case accountName
    case virtualAccountName
    case postingComment
    case trailingComment

    /// The path the error names when this is the broken field.
    var path: String {
        switch self {
        case .description: "description"
        case .code: "code"
        case .comment: "comment"
        case .leadingComment: "leadingComments[0]"
        case .accountName: "postings[1].accountName"
        case .virtualAccountName: "postings[2].accountName"
        case .postingComment: "postings[1].comment"
        case .trailingComment: "postings[1].trailingComments[1]"
        }
    }

    /// A balanced transaction that is valid in every way but this one field,
    /// which is written as `text`.
    func transaction(holding text: String) throws -> Transaction {
        try Transaction(
            date: makeDate(2024, 1, 1),
            code: self == .code ? text : "CHQ001",
            description: self == .description ? text : "Groceries",
            postings: [
                Posting(accountName: "Expenses:Food", amount: usd(5)),
                Posting(
                    accountName: self == .accountName ? text : "Assets:Cash",
                    amount: usd(-5),
                    comment: self == .postingComment ? text : "paid in cash",
                    trailingComments: [
                        "    ; a note",
                        self == .trailingComment ? text : "    ; a second note",
                    ],
                ),
                Posting(
                    accountName: self == .virtualAccountName ? text : "Reserve:capital",
                    kind: .virtual,
                    amount: usd(1),
                ),
            ],
            comment: self == .comment ? text : "weekly shop",
            leadingComments: [self == .leadingComment ? text : "    ; invoice 42"],
        )
    }
}

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
        #expect(throws: LedgerError.unbalancedTransaction(residuals: [usd(-50)])) {
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
    func `a transaction with no postings is valid, an empty sum being zero`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "just a payee", postings: [],
        )
        #expect(transaction.postings.isEmpty)
        #expect(transaction.description == "just a payee")
    }

    @Test
    func `a lone posting of zero is valid`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "zero",
            postings: [
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: 0, commodity: "USD")),
            ],
        )
        #expect(transaction.postings.count == 1)
        #expect(transaction.postings[0].amount.quantity == 0)
    }

    @Test
    func `a lone non-zero posting is unbalanced, and says so`() throws {
        let date = try makeDate(2024, 1, 1)
        #expect(throws: LedgerError.unbalancedTransaction(residuals: [usd(100)])) {
            try Transaction(
                date: date, description: "Single",
                postings: [
                    Posting(accountName: "Assets:Cash", amount: Amount(quantity: 100, commodity: "USD")),
                ],
            )
        }
    }

    @Test
    func `a transaction balances its real and bracketed postings apart`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "Groceries and the envelope",
            postings: [
                Posting(accountName: "Expenses:Food", amount: usd(60)),
                Posting(accountName: "Assets:Cash", amount: usd(-60)),
                Posting(accountName: "Envelope:Food", kind: .balancedVirtual, amount: usd(-60)),
                Posting(accountName: "Envelope:Free", kind: .balancedVirtual, amount: usd(60)),
                Posting(accountName: "Reserve:capital", kind: .virtual, amount: usd(250_000)),
            ],
        )
        #expect(transaction.postings.count == 5)
    }

    @Test
    func `a transaction whose bracketed postings do not net to zero throws`() throws {
        let date = try makeDate(2024, 1, 1)
        #expect(throws: LedgerError.unbalancedBracketedPostings(residuals: [usd(5)])) {
            try Transaction(
                date: date, description: "Bad envelope",
                postings: [
                    Posting(accountName: "Expenses:Food", amount: usd(60)),
                    Posting(accountName: "Assets:Cash", amount: usd(-60)),
                    Posting(accountName: "Envelope:Food", kind: .balancedVirtual, amount: usd(-55)),
                    Posting(accountName: "Envelope:Free", kind: .balancedVirtual, amount: usd(60)),
                ],
            )
        }
    }

    /// Balance compares postings by content — to re-anchor an edit after a
    /// reparse, and to weigh two versions of a file against each other — so an
    /// envelope leg must not read as the same posting as an ordinary one.
    @Test
    func `two postings differing only in kind are not equal`() {
        let amount = usd(60)
        let real = Posting(accountName: "Reserve:capital", amount: amount)
        let virtual = Posting(accountName: "Reserve:capital", kind: .virtual, amount: amount)
        #expect(real != virtual)
        #expect(Set([real, virtual]).count == 2)
    }

    /// A real posting's name is written bare, so a name that is itself a
    /// matched pair would be the line a virtual posting writes and would come
    /// back from the next parse in the other balancing group: the real group
    /// loses the leg, the entry no longer balances, and the whole file stops
    /// loading over one account somebody named `(old)`. The name is the only
    /// place to catch it.
    @Test(arguments: ["(old)", "[Reserved]", "( spaced )"])
    func `a real posting may not be named a matched pair of delimiters`(name: String) throws {
        let date = try makeDate(2024, 1, 1)
        #expect(throws: LedgerError.unwritableAccountName(name)) {
            try Transaction(
                date: date, description: "typed by a user",
                postings: [
                    Posting(accountName: name, amount: usd(5)),
                    Posting(accountName: "Assets:Bank", amount: usd(-5)),
                ],
            )
        }
    }

    /// Only a whole matched pair is refused. Delimiters anywhere else in a
    /// name survive a round trip untouched, and a virtual posting may be named
    /// anything at all: its own delimiters go on top.
    @Test
    func `delimiters that are not the whole name are still allowed`() throws {
        let date = try makeDate(2024, 1, 1)
        let transaction = try Transaction(
            date: date, description: "typed by a user",
            postings: [
                Posting(accountName: "Assets:Car (old)", amount: usd(5)),
                Posting(accountName: "Assets:Bank", amount: usd(-5)),
                Posting(accountName: "(old)", kind: .virtual, amount: usd(1)),
            ],
        )
        #expect(transaction.postings.map(\.accountName) == ["Assets:Car (old)", "Assets:Bank", "(old)"])
    }

    /// A journal writes each of these fields on a line of its own and the
    /// serializer writes the value verbatim, so a break inside one puts the
    /// rest of it on a line where the next parse reads it as a directive or as
    /// a lone elided posting. A postingless entry being valid, nothing
    /// downstream objects and the amounts below the break stop counting, so
    /// this is the one place to refuse it.
    ///
    /// All three spellings a file can carry a break in are tried. `\r\n` is
    /// the one that matters: Swift folds it into a single `Character` that is
    /// neither `\n` nor `\r`, so a check written over characters rather than
    /// scalars waves through exactly the spelling Windows produces.
    @Test(arguments: OneLineField.allCases, ["\n", "\r", "\r\n"])
    func `a field a journal writes on one line refuses a line break`(
        field: OneLineField, lineBreak: String,
    ) throws {
        #expect(throws: LedgerError.lineBreakInField(field.path)) {
            try field.transaction(holding: "Multi\(lineBreak)line")
        }
    }

    /// A value that cannot be written is the more basic complaint, so it is
    /// the one the caller hears, ahead of both the other checks. An entry
    /// whose description holds a break and whose postings do not add up names
    /// the description rather than the dollars, and an account name that
    /// holds one is reported for the break rather than for the matched pair
    /// it also happens to be.
    @Test
    func `a line break is reported before the imbalance or the bare name`() throws {
        #expect(throws: LedgerError.lineBreakInField("description")) {
            try Transaction(
                date: makeDate(2024, 1, 1),
                description: "Multi\nline",
                postings: [Posting(accountName: "Assets:Cash", amount: usd(100))],
            )
        }
        #expect(throws: LedgerError.lineBreakInField("postings[0].accountName")) {
            try Transaction(
                date: makeDate(2024, 1, 1),
                description: "Groceries",
                postings: [Posting(accountName: "(a\nb)", amount: usd(0))],
            )
        }
    }

    @Test
    func `the line-break message names the field path`() {
        let error = LedgerError.lineBreakInField("postings[1].accountName")
        #expect(error.errorDescription == "Field 'postings[1].accountName' contains a line break "
            + "and cannot be written on one line")
    }

    /// Only a break is refused. Tabs and runs of spaces are ordinary content
    /// of a one-line field and have to go on building.
    @Test
    func `other whitespace in a one-line field still builds`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1),
            code: "CHQ 001",
            description: "Corner\tShop  supplies",
            postings: [
                Posting(accountName: "Expenses:Food", amount: usd(5), comment: "two  spaces"),
                Posting(accountName: "Assets:Cash", amount: usd(-5)),
            ],
            comment: "weekly  shop",
        )
        #expect(transaction.description == "Corner\tShop  supplies")
        #expect(transaction.postings[0].comment == "two  spaces")
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

/// Every text a transaction holds that a journal writes on one line, the
/// verbatim comment lines included, for a test that none of them kept the
/// `\r` of a Windows line ending.
private func oneLineTexts(of transaction: Transaction) -> [String] {
    [transaction.description, transaction.code, transaction.comment].compactMap(\.self)
        + transaction.leadingComments
        + transaction.postings.flatMap { posting in
            [posting.accountName, posting.comment].compactMap(\.self) + posting.trailingComments
        }
}

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
    func `two elided postings in one transaction throws multipleElidedPostings`() throws {
        let text = """
        2024-01-01 Bad
            Assets:Cash
            Income:Sales
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .multipleElidedPostings)
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

// MARK: - JournalParser: validating a number and reading its marks

/// `parseAmount` used to strip every `,` and hand the rest to
/// `Decimal(string:)`, which keeps the longest prefix that parses and drops
/// the rest without a word. A journal of `$1e5` and `€12,50` therefore loaded,
/// balanced, and reported figures nobody had written (issue #18). The number
/// is validated here instead, and which of its marks divides the fraction is
/// read out of the number itself.
@Suite("amount validation") struct AmountValidationTests {
    private func value(_ raw: String) throws -> Decimal {
        try JournalParser().parseAmount(raw, lineNumber: 1).quantity
    }

    /// The rows of the issue's table that were read as a number they are not.
    @Test(arguments: [
        "$1x2y", "$-1x2y", "$1e5", "$-1e5", "$1_000", "$-1_000", "$0x10", "$-0x10", "$.",
    ])
    func `an amount that is not a number is refused`(raw: String) throws {
        #expect(throws: LedgerError.invalidAmount(raw)) {
            try JournalParser().parseAmount(raw, lineNumber: 1)
        }
    }

    /// The other rows: a comma dividing the fraction was multiplying the
    /// amount by a hundred.
    @Test
    func `a comma before two digits divides the fraction`() throws {
        #expect(try value("€1,50") == Decimal(string: "1.5"))
        #expect(try value("€-1,50") == Decimal(string: "-1.5"))
        #expect(try value("1,50 EUR") == Decimal(string: "1.5"))
        #expect(try value("-1,50 EUR") == Decimal(string: "-1.5"))
    }

    @Test
    func `with two different marks the last one divides the fraction`() throws {
        #expect(try value("1,000.00") == 1000)
        #expect(try value("1.000,00") == 1000)
        #expect(try value("12.345,678") == Decimal(string: "12345.678"))
    }

    @Test
    func `one mark written more than once groups the digits`() throws {
        #expect(try value("1,000,000") == 1_000_000)
        #expect(try value("1.000.000") == 1_000_000)
        // Indian grouping, which hledger reads this way too. ledger-cli wants
        // groups of three and refuses it outright, so no journal either tool
        // loads disagrees with this reading.
        #expect(try value("1,00,000") == 100_000)
    }

    /// The one shape the number cannot settle on its own. Both readings are in
    /// use in the wild, and the tie-break kept is the one this library and
    /// ledger-cli have always had.
    @Test
    func `a mark before exactly three digits keeps the old reading`() throws {
        #expect(try value("1,000") == 1000)
        #expect(try value("1.000") == 1)
    }

    /// Nothing groups a zero, so the tie-break never reaches a number whose
    /// integer part is one. hledger reads these the same way, and ledger's own
    /// source carries the same exception. A three-decimal currency writes them
    /// all day, which is what makes the old reading, `€0,750` as seven hundred
    /// and fifty euros, worth ruling out.
    @Test
    func `a mark with only zeros in front of it divides the fraction`() throws {
        #expect(try value("0,500") == Decimal(string: "0.5"))
        #expect(try value("0,075") == Decimal(string: "0.075"))
        #expect(try value("€0,750") == Decimal(string: "0.75"))
        #expect(try value("10,500") == 10500)
    }

    @Test
    func `a mark before any other count of digits divides the fraction`() throws {
        #expect(try value("12,50") == Decimal(string: "12.5"))
        #expect(try value("1,5") == Decimal(string: "1.5"))
        #expect(try value("1,0000") == 1)
        #expect(try value(".5") == Decimal(string: "0.5"))
        #expect(try value(",5") == Decimal(string: "0.5"))
        #expect(try value("5.") == 5)
        #expect(try value("5,") == 5)
    }

    /// A group mark needs a digit on each side, and every group mark has to be
    /// the same character.
    @Test(arguments: [",000", "1,,000", "1,000,", "1,.5", "1.000,000.00", "."])
    func `a number whose marks do not add up is refused`(raw: String) throws {
        #expect(throws: LedgerError.invalidAmount(raw)) {
            try JournalParser().parseAmount(raw, lineNumber: 1)
        }
    }

    /// Nothing that is not a digit or a mark belongs in a number. With the
    /// commodity in front, the whole of the rest of the text is the number, so
    /// there is nowhere for the stray characters to hide.
    @Test(arguments: ["$1e5", "$0x10", "$1_000", "$1x2y", "$1 000", "$1-2", "$100 USD"])
    func `a number carrying anything else is refused`(raw: String) throws {
        #expect(throws: LedgerError.invalidAmount(raw)) {
            try JournalParser().parseAmount(raw, lineNumber: 1)
        }
    }

    /// A digit is not a digit because Foundation says so. `Character.isNumber`
    /// is true of half a dozen kinds of character `Decimal(string:)` cannot
    /// read, and a range test over `"0" ... "9"` lets a combining accent in,
    /// where `Decimal(string:)` takes the digits before it and drops the rest.
    @Test(arguments: ["$5\u{0301}", "$1\u{0301},000", "5\u{0301} EUR", "$１", "$٣", "$½"])
    func `a digit from outside ASCII is not a number`(raw: String) throws {
        #expect(throws: LedgerError.invalidAmount(raw)) {
            try JournalParser().parseAmount(raw, lineNumber: 1)
        }
    }

    /// Written the other way round, what follows the digits is the commodity,
    /// which is how `10AAPL` is a share count in both tools and how this has
    /// always read. A quoted symbol is kept exactly as written, quotes and all,
    /// since the quoting is not modelled here and a file using it loaded
    /// before.
    @Test
    func `letters after a bare number name the commodity`() throws {
        let shares = try JournalParser().parseAmount("10AAPL", lineNumber: 1)
        #expect(shares.quantity == 10)
        #expect(shares.commodity == "AAPL")

        let dollars = try JournalParser().parseAmount("100USD", lineNumber: 1)
        #expect(dollars.quantity == 100)
        #expect(dollars.commodity == "USD")

        let quoted = try JournalParser().parseAmount("10 \"AAPL 2\"", lineNumber: 1)
        #expect(quoted.quantity == 10)
        #expect(quoted.commodity == "\"AAPL 2\"")
    }

    /// An unquoted commodity symbol carries no digit in either tool, so the
    /// bare forms from the issue are a mistyped number rather than one unit of
    /// `e5` or of `x2y`. The number also has to stop of its own accord: text
    /// beginning where the digits could have carried on means it was cut
    /// short, not that the commodity began.
    @Test(arguments: ["1e5", "0x10", "1_000", "1x2y", "1 000 EUR", "1-2"])
    func `a bare number that runs into its commodity is refused`(raw: String) throws {
        #expect(throws: LedgerError.invalidAmount(raw)) {
            try JournalParser().parseAmount(raw, lineNumber: 1)
        }
    }

    /// The journal from the issue, which used to load without complaint and
    /// report `€-1249` where the file says nine hundred and eighty-seven fifty.
    @Test
    func `the european journal from the issue loads with its own numbers`() throws {
        let text = """
        commodity 1.000,00 EUR
        D 1.000,00 EUR

        2024-01-01 opening
            assets:bank      €1.000,00
            equity:opening  €-1.000,00

        2024-01-02 groceries
            expenses:food       €12,50
            assets:bank        €-12,50
        """
        let journal = try JournalParser().parse(text)
        let ledger = Ledger(journal: journal)
        #expect(try ledger.balance(for: "assets:bank") == [
            Amount(quantity: #require(Decimal(string: "987.50")), commodity: "€", commodityIsPrefix: true),
        ])
        #expect(try ledger.balance(for: "expenses:food") == [
            Amount(quantity: #require(Decimal(string: "12.50")), commodity: "€", commodityIsPrefix: true),
        ])
        // The directives are read for the style they state and kept verbatim
        // all the same, so the file still goes back byte for byte.
        #expect(journal.directives == ["commodity 1.000,00 EUR", "D 1.000,00 EUR"])
        #expect(JournalSerializer().serialize(journal) == text)
        #expect(journal.commodityFormats["EUR"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["EUR"]?.groupsThousands == true)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")
        #expect(journal.commodityFormats["EUR"]?.groupMark == ".")
        #expect(journal.commodityFormats["€"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["€"]?.decimalMark == ",")
    }

    /// A file written with a comma decimal mark says two fraction digits and
    /// no grouping, and a posting rebuilt from it still means what it meant
    /// and is still spelled the way the file spells it.
    @Test
    func `a comma-decimal file records two fraction digits and no grouping`() throws {
        let text = """
        2024-01-02 groceries
            expenses:food       €12,50
            assets:bank        €-12,50
        """
        var journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["€"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["€"]?.groupsThousands == false)

        try renaming(#require(journal.transactions.first), to: "groceries (revised)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("€12,50"))
        #expect(written.contains("€-12,50"))
        let rebuilt = try JournalParser().parse(written)
        let entry = try #require(rebuilt.transactions.first)
        #expect(try entry.postings.map(\.amount.quantity) == [
            #require(Decimal(string: "12.50")), #require(Decimal(string: "-12.50")),
        ])
    }

    /// A directive states a style and may say why in the same breath. The
    /// sample is what comes before the `;`, since a scanner handed the comment
    /// refuses the lot and the declaration disappears without a word.
    @Test
    func `a directive with a comment still declares its style`() throws {
        let journal = try JournalParser().parse("""
        D $1,000.00 ; house style
        commodity 1.000,00 EUR ; two decimals, points for thousands
        """)
        #expect(journal.commodityFormats["$"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["$"]?.groupsThousands == true)
        #expect(journal.commodityFormats["$"]?.decimalMark == ".")
        #expect(journal.commodityFormats["EUR"]?.fractionDigits == 2)
        #expect(journal.commodityFormats["EUR"]?.groupsThousands == true)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")
    }

    /// A journal saved on Windows, read for its amounts. `parse` splits on
    /// `\n` and `parseTransaction` takes the `\r` off each of a transaction's
    /// lines, so an amount that ends its line reaches the scanner spelled the
    /// way the same file with Unix endings spells it. The file loaded before
    /// any of that existed, and has to go on loading and going back byte for
    /// byte. What its fields hold is the test below.
    @Test
    func `a journal with windows line endings still loads`() throws {
        let text = [
            "2026-08-04 An expense",
            "    assets                            $-66.00",
            "    expenses                           $66.00",
            "",
            "2026-08-05 In euros",
            "    assets                         100.00 EUR",
            "    equity                        -100.00 EUR",
        ].joined(separator: "\r\n")
        let journal = try JournalParser().parse(text)
        let amounts = journal.transactions.flatMap { $0.postings.map(\.amount) }
        #expect(amounts.map(\.quantity) == [-66, 66, 100, -100])
        #expect(amounts.map(\.commodity) == ["$", "$", "EUR", "EUR"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// The same file read for what its fields say rather than for its amounts.
    /// Every field that runs to the end of a line used to keep the `\r` that
    /// closed it: a description, an inline comment, a full-line comment, and
    /// worst of them an elided posting's account name, which named an account
    /// no other entry named and so left the amount it should have absorbed out
    /// of every balance.
    ///
    /// The margin the file teaches is checked against the same file written
    /// with Unix endings, since an amount that ends its own line used to be
    /// measured one column wider than the file draws it.
    @Test
    func `a windows file keeps its line endings out of the fields`() throws {
        let lines = [
            "2026-08-04 * (CHQ001) Groceries  ; weekly shop",
            "    ; invoice 42, paid late",
            "    Expenses:Food:Groceries                 $66.00  ; the usual",
            "    ; the receipt is in the folder",
            "    Expenses:Food:Drinks                     $4.00",
            "    Assets:Checking",
            "",
            "2026-08-05 A note to self",
        ]
        let text = lines.joined(separator: "\r\n")
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.count == 2)

        let groceries = try #require(journal.transactions.first)
        #expect(groceries.code == "CHQ001")
        #expect(groceries.description == "Groceries")
        #expect(groceries.comment == "weekly shop")
        #expect(groceries.leadingComments == ["    ; invoice 42, paid late"])
        #expect(groceries.postings[0].comment == "the usual")
        #expect(groceries.postings[0].trailingComments == ["    ; the receipt is in the folder"])
        // The elided line names the account the file names, not a second one
        // spelled with a line ending on the end of it.
        #expect(groceries.postings[2].accountName == "Assets:Checking")
        #expect(groceries.postings.map(\.amount.quantity) == [66, 4, -70])

        let note = journal.transactions[1]
        #expect(note.description == "A note to self")
        #expect(note.postings.isEmpty)

        let texts = journal.transactions.flatMap(oneLineTexts(of:))
        #expect(!texts.contains { $0.unicodeScalars.contains("\r") })
        #expect(JournalSerializer().serialize(journal) == text)

        // The margin the file teaches, against the same file written with Unix
        // endings. The amount that ends its own line used to be measured a
        // character wider here than there, which moved the margin with it.
        let unix = try JournalParser().parse(lines.joined(separator: "\n"))
        #expect(unix.amountAlignment == .end(column: 50))
        #expect(journal.amountAlignment == unix.amountAlignment)
    }

    /// A `\r` anywhere but at the end of a line is not a line ending, and the
    /// field it lands in really is one a journal cannot write. The file says
    /// so and refuses to load, rather than being quietly mended into a
    /// description nobody typed.
    @Test
    func `a carriage return inside a header line refuses to load`() throws {
        let text = [
            "2026-08-04 Corner\rShop",
            "    Expenses:Food:Groceries  $1.00",
            "    Assets:Checking  $-1.00",
        ].joined(separator: "\r\n")
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .lineBreakInField("description"))
    }

    @Test
    func `a price is validated like any other amount`() throws {
        let text = """
        2024-01-01 buy
            assets:brokerage    10 AAPL @ $1x
            assets:checking          $-1500.00
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .invalidAmount("$1x"))
    }

    @Test
    func `a balance assertion reads its marks the way an amount does`() throws {
        let text = """
        2024-01-02 statement
            assets:bank    €0 = €1.000,00
        """
        let entry = try #require(JournalParser().parse(text).transactions.first)
        #expect(entry.postings.first?.balanceAssertion?.quantity == 1000)
    }
}

// MARK: - JournalParser: where in the journal an error was found

/// Nine entries that load, and then one that does not, whose header lands on
/// line 37.
///
/// The journals of issue #50, where every message named what was wrong and
/// none of them named where it was, leaving a reader with a file that will not
/// open and nothing to search for.
private func journalEndingWith(_ entry: String) -> String {
    let good = (1 ... 9).flatMap { index in
        [
            "2026-01-0\(index) Entry \(index)",
            "    Expenses:Food       $10.00",
            "    Assets:Checking    $-10.00",
            "",
        ]
    }
    return (good + [entry]).joined(separator: "\n")
}

/// One row of that issue's table: an entry that will not load, the line the
/// error now names, and the error it still is underneath.
private struct BadEntry {
    var text: String
    var line: Int
    var cause: LedgerError

    /// The header the error names the entry by.
    var header: String {
        text.components(separatedBy: "\n")[0]
    }
}

private let badEntries: [BadEntry] = [
    BadEntry(
        text: """
        2026-02-01 Off by one
            Expenses:Food       $10.00
            Assets:Checking      $-9.00
        """,
        line: 37,
        cause: .unbalancedTransaction(residuals: [dollars(1)]),
    ),
    BadEntry(
        text: """
        2026-02-01 A space in the number
            Expenses:Food       $1 000
            Assets:Checking  $-1000.00
        """,
        line: 38,
        cause: .invalidAmount("$1 000"),
    ),
    BadEntry(
        text: """
        2026-02-01 An exponent in the number
            Expenses:Food         $1e5
            Assets:Checking   $-100000
        """,
        line: 38,
        cause: .invalidAmount("$1e5"),
    ),
    BadEntry(
        text: """
        2026-02-01 The envelope is off by one
            Expenses:Food       $10.00
            Assets:Checking    $-10.00
            [Envelope:Food]      $-9.00
            [Envelope:Free]     $10.00
        """,
        line: 37,
        cause: .unbalancedBracketedPostings(residuals: [dollars(1)]),
    ),
    BadEntry(
        text: """
        2026-02-01 Two blank amounts
            Expenses:Food       $10.00
            Assets:Checking
            Assets:Savings
        """,
        line: 37,
        cause: .multipleElidedPostings,
    ),
    BadEntry(
        text: "2026-02-01 Corner\rShop\n    Expenses:Food       $10.00\n    Assets:Checking    $-10.00",
        line: 37,
        cause: .lineBreakInField("description"),
    ),
]

private extension LedgerError {
    /// The entry a located error names, or `nil` when the error does not say
    /// where in a journal it was found.
    var locatedEntry: String? {
        guard case let .inJournal(_, entry, _) = self else { return nil }
        return entry
    }
}

/// An error thrown while a journal loads says where it was found, so that the
/// person reading it can open the file at that line (issue #50).
@Suite("located load errors") struct LocatedLoadErrorTests {
    /// Every row of the issue's table: the same error as before, wrapped in
    /// the place it was found. The two invalid amounts are written on a
    /// posting line rather than on the header and report that line; the entry
    /// to open is the same one either way.
    @Test(arguments: badEntries)
    private func `an entry that will not load says where it is`(bad: BadEntry) throws {
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(journalEndingWith(bad.text))
        }
        #expect(error.line == bad.line)
        #expect(error.locatedEntry == bad.header)
        #expect(error.withoutLocation == bad.cause)
        #expect(
            error.localizedDescription
                == "Line \(bad.line), \"\(bad.header)\": \(bad.cause.localizedDescription)",
        )
    }

    /// An amount, a price and an assertion are written on a posting's line, so
    /// that is the line reported. An entry can run to a dozen postings, and
    /// the header alone would send the reader to the right entry and the wrong
    /// line. It is named too, not instead.
    @Test(arguments: [
        ("    Assets:Savings       $1 000", "$1 000"),
        ("    Assets:Brokerage     10 AAPL @ $1x", "$1x"),
        ("    Assets:Savings       $10.00 = $1 000", "$1 000"),
    ])
    func `a bad amount, price or assertion reports the posting's own line`(
        posting: String, raw: String,
    ) throws {
        let entry = [
            "2026-02-01 Third line",
            "    Expenses:Food       $10.00",
            posting,
        ].joined(separator: "\n")
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(journalEndingWith(entry))
        }
        #expect(error.line == 39)
        #expect(error.locatedEntry == "2026-02-01 Third line")
        #expect(error.withoutLocation == .invalidAmount(raw))
    }

    /// A date that is no date is the header's own problem, and is reported
    /// against the header's line.
    @Test
    func `an impossible date reports the header line`() throws {
        let entry = "2026-13-45 Foo\n    Assets:Cash          $0.00"
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(journalEndingWith(entry))
        }
        #expect(error.line == 37)
        #expect(error.locatedEntry == "2026-13-45 Foo")
        #expect(error.withoutLocation == .invalidDate("2026-13-45"))
    }

    /// A Windows journal counts its lines exactly as the same text with Unix
    /// endings does, and the entry it names does not come back with the other
    /// half of its line ending attached.
    @Test
    func `a journal with Windows endings reports the same place`() throws {
        let unix = journalEndingWith("""
        2026-02-01 Off by one
            Expenses:Food       $10.00
            Assets:Checking      $-9.00
        """)
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        let fromUnix = try #require(throws: LedgerError.self) { try JournalParser().parse(unix) }
        let fromWindows = try #require(throws: LedgerError.self) { try JournalParser().parse(windows) }
        #expect(fromWindows == fromUnix)
        #expect(fromWindows.line == 37)
        #expect(fromWindows.locatedEntry == "2026-02-01 Off by one")
        #expect(fromWindows.locatedEntry?.contains("\r") == false)
    }

    /// A transaction built in code has no line to report and throws what it
    /// always threw, which is the error `withoutLocation` hands back for the
    /// one read out of a file.
    @Test
    func `a transaction built in code throws the bare error`() throws {
        let error = try #require(throws: LedgerError.self) {
            try Transaction(
                date: makeDate(2026, 2, 1), description: "Off by one",
                postings: [
                    Posting(accountName: "Expenses:Food", amount: usd(10)),
                    Posting(accountName: "Assets:Checking", amount: usd(-9)),
                ],
            )
        }
        #expect(error == .unbalancedTransaction(residuals: [usd(1)]))
        #expect(error.line == nil)
        #expect(error.locatedEntry == nil)
        #expect(error.withoutLocation == error)
    }

    /// `parseError` said where it was found before any of this, and is handed
    /// back as it is rather than wrapped in a second line number.
    @Test
    func `a parse error keeps the line it always carried`() throws {
        let entry = "2026-02-01=2026 Aux\n    Assets:Cash          $0.00"
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(journalEndingWith(entry))
        }
        #expect(error == .parseError(line: 37, message: "Expected date, got '2026 Aux'"))
        #expect(error.line == 37)
        #expect(error.withoutLocation == error)
        #expect(error.localizedDescription == "Parse error on line 37: Expected date, got '2026 Aux'")
    }

    /// The place survives the journey a real caller makes: out of the file,
    /// through the store, and out of both the first load and a reload of a
    /// journal that went wrong while it was open.
    @Test
    func `a located error reaches a manager through the store`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }
        let bad = journalEndingWith("""
        2026-02-01 Off by one
            Expenses:Food       $10.00
            Assets:Checking      $-9.00
        """)

        try bad.write(to: url, atomically: true, encoding: .utf8)
        let onLoad = try #require(throws: LedgerError.self) {
            try LedgerManager(store: PlainTextJournalStore(url: url))
        }
        #expect(onLoad.line == 37)
        #expect(onLoad.withoutLocation == .unbalancedTransaction(residuals: [dollars(1)]))

        try journalEndingWith("").write(to: url, atomically: true, encoding: .utf8)
        let manager = try LedgerManager(store: PlainTextJournalStore(url: url))
        try bad.write(to: url, atomically: true, encoding: .utf8)
        let onReload = try #require(throws: LedgerError.self) { try manager.reload() }
        #expect(onReload.line == 37)
        #expect(onReload.locatedEntry == "2026-02-01 Off by one")
    }
}

// MARK: - JournalParser: multi-commodity elision

/// An elided amount takes the remainder of every commodity its balancing
/// group leaves over, which is what lets the standard opening-balances entry
/// load. One written line therefore becomes one posting per commodity.
@Suite("multi-commodity elision") struct MultiCommodityElisionTests {
    /// The opening-balances entry every hledger tutorial starts with: two
    /// commodities, one line to absorb both. Since a `Posting` holds a single
    /// amount, that line resolves into one posting per commodity, in commodity
    /// order.
    @Test
    func `an elided posting absorbs the remainder of every commodity in the entry`() throws {
        let text = """
        2024-01-01 opening balances
            assets:bank:checking   $1000
            assets:bank:savings    £500
            equity:opening balances
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 4)
        #expect(transaction.postings[2].accountName == "equity:opening balances")
        #expect(transaction.postings[3].accountName == "equity:opening balances")
        #expect(transaction.postings[2].amount == Amount(quantity: -1000, commodity: "$", commodityIsPrefix: true))
        #expect(transaction.postings[3].amount == Amount(quantity: -500, commodity: "£", commodityIsPrefix: true))
    }

    /// The order is the commodities' own, not the entry's: that is what
    /// hledger prints, and it is the order every multi-commodity answer in
    /// this library comes in, so a balance and the entry behind it read the
    /// same way round.
    @Test
    func `the absorbed commodities come back in commodity order`() throws {
        let text = """
        2024-01-01 opening balances
            assets:gbp       10 GBP
            assets:eur      100 EUR
            assets:usd     -110 USD
            equity:opening
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.suffix(3).map(\.amount) == [
            Amount(quantity: -100, commodity: "EUR"),
            Amount(quantity: -10, commodity: "GBP"),
            Amount(quantity: 110, commodity: "USD"),
        ])
    }

    /// A commodity the written legs already balance leaves nothing to absorb,
    /// so the elided line gets no leg in it. An entry does not need a `$0`
    /// posting to say what its dollar legs already said.
    @Test
    func `a commodity that already balances gets no leg from the elided posting`() throws {
        let text = """
        2024-01-01 opening balances
            assets:cash             $100
            assets:petty            $-100
            assets:bank:savings     £50
            equity:opening balances
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 4)
        #expect(transaction.postings[3].accountName == "equity:opening balances")
        #expect(transaction.postings[3].amount == Amount(quantity: -50, commodity: "£", commodityIsPrefix: true))
    }

    /// A priced leg is absorbed at what it cost, in the price's commodity, so
    /// a share purchase and a pound leg leave a dollar remainder and a pound
    /// one rather than an `AAPL` remainder.
    @Test
    func `an elided posting absorbs a priced leg at cost alongside another commodity`() throws {
        let text = """
        2024-01-01 opening balances
            assets:brokerage        10 AAPL @ $150.00
            assets:bank:savings     £100
            equity:opening balances
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 4)
        #expect(transaction.postings[2].amount == Amount(quantity: -1500, commodity: "$", commodityIsPrefix: true))
        #expect(transaction.postings[3].amount == Amount(quantity: -100, commodity: "£", commodityIsPrefix: true))
    }

    /// One written line becomes several postings, so the fields that belong to
    /// the line rather than to an amount have to land somewhere a reader would
    /// look for them: the status on every posting, the inline comment on the
    /// first, the comments written underneath on the last, and the assertion
    /// on the posting in the commodity it names.
    @Test
    func `an expanded elided posting spreads the fields of the line it was written on`() throws {
        let text = """
        2024-01-01 opening balances
            assets:bank:checking   $1000
            assets:bank:savings    £500
            ! equity:opening balances  = £-500  ; the pair of them
            ; counted on the first of the year
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        let expanded = transaction.postings.filter { $0.accountName == "equity:opening balances" }
        #expect(expanded.count == 2)
        #expect(expanded.map(\.status) == [.pending, .pending])
        #expect(expanded.map(\.comment) == ["the pair of them", nil])
        #expect(expanded[0].trailingComments.isEmpty)
        #expect(expanded[1].trailingComments == ["    ; counted on the first of the year"])
        #expect(expanded[0].balanceAssertion == nil)
        #expect(expanded[1].amount.commodity == "£")
        #expect(expanded[1].balanceAssertion == Amount(quantity: -500, commodity: "£", commodityIsPrefix: true))
    }

    /// `cannotResolveElision` used to be what a two-commodity entry got, and
    /// nothing throws it from a parse any more: an elision with nothing to
    /// balance against reads as zero, the way hledger reads it, and a second
    /// elided posting in the same group is `multipleElidedPostings`. The case
    /// stays in `LedgerError` because it is public API, and it still says what
    /// it is for.
    @Test
    func `an elided posting with nothing to balance against reads as zero`() throws {
        let text = """
        2024-01-01 opening balances
            equity:opening balances
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.count == 1)
        #expect(transaction.postings[0].amount.quantity == .zero)
        #expect(
            LedgerError.cannotResolveElision.errorDescription
                == "Cannot resolve elided amount: no explicit amount to balance it against",
        )
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

// MARK: - JournalParser: a comment after an amount

/// The two-space rule ends an account name, not an amount, so once the name
/// has ended a `;` opens the posting's comment however few spaces sit before
/// it. The entry below came in on issue #18 from a real journal that hledger
/// reads without complaint; here the amount came through as 66 and the comment
/// was dropped in silence.
@Suite("comments after an amount") struct PostingCommentTests {
    private static let oneSpace = """
    2026-08-04 An expense
        assets                            $-66.00
        expenses                           $66.00 ; an expense
    """

    @Test
    func `a comment one space after an amount is a comment`() throws {
        let entry = try #require(JournalParser().parse(Self.oneSpace).transactions.first)
        #expect(entry.postings.map(\.amount.quantity) == [-66, 66])
        #expect(entry.postings.map(\.comment) == [nil, "an expense"])
    }

    @Test
    func `the entry with the comment goes back byte for byte`() throws {
        let journal = try JournalParser().parse(Self.oneSpace)
        #expect(JournalSerializer().serialize(journal) == Self.oneSpace)
    }

    /// No space at all is the same line: what ends the amount is the `;`, not
    /// the gap in front of it.
    @Test
    func `a comment written straight after an amount is a comment`() throws {
        let text = """
        2026-08-04 An expense
            assets                            $-66.00
            expenses                           $66.00; an expense
        """
        let journal = try JournalParser().parse(text)
        let entry = try #require(journal.transactions.first)
        #expect(entry.postings.map(\.amount.quantity) == [-66, 66])
        #expect(entry.postings.map(\.comment) == [nil, "an expense"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// An untouched file always survived a save, since it is replayed from its
    /// own lines. The comment was lost the moment anything rebuilt the entry,
    /// which is what an edit, a rename or a reconcile does.
    @Test
    func `a rebuilt entry writes the comment back`() throws {
        var journal = try JournalParser().parse(Self.oneSpace)
        try renaming(#require(journal.transactions.first), to: "An expense (revised)", in: &journal)
        #expect(JournalSerializer().serialize(journal).contains("$66.00  ; an expense"))
    }

    @Test
    func `the two-space form reads the same way`() throws {
        let text = """
        2026-08-04 An expense
            assets                            $-66.00
            expenses                           $66.00  ; an expense
        """
        let journal = try JournalParser().parse(text)
        let entry = try #require(journal.transactions.first)
        #expect(entry.postings.map(\.comment) == [nil, "an expense"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Everything from the first `;` is the comment, so a `;` written inside
    /// one stays inside it rather than starting a second.
    @Test
    func `only the first semicolon opens the comment`() throws {
        let text = """
        2026-08-04 An expense
            assets                            $-66.00
            expenses                           $66.00 ; an expense ; paid in cash
        """
        let entry = try #require(JournalParser().parse(text).transactions.first)
        #expect(entry.postings.last?.comment == "an expense ; paid in cash")
    }

    /// A posting that writes no amount has no amount field for the rule to
    /// apply to, so its `;` still needs the two spaces that end an account
    /// name. With one space the `;` is part of the name, which is what this
    /// has always done.
    @Test
    func `a posting with no amount keeps the two-space rule`() throws {
        let text = """
        2026-08-04 A note
            expenses ; not a comment
        """
        let entry = try #require(JournalParser().parse(text).transactions.first)
        #expect(entry.postings.map(\.accountName) == ["expenses ; not a comment"])
        #expect(entry.postings.first?.comment == nil)

        let spaced = try JournalParser().parse("""
        2026-08-04 A note
            expenses  ; a comment
        """)
        #expect(spaced.transactions.first?.postings.first?.accountName == "expenses")
        #expect(spaced.transactions.first?.postings.first?.comment == "a comment")
    }

    /// The margin is measured on the field the comment has already been taken
    /// out of. This entry ends both its amounts at column 45; counting the
    /// comment as part of the field would put one of them at 58 and hand the
    /// file a margin no amount in it stands at.
    @Test
    func `a comment does not move the margin the file teaches`() throws {
        let journal = try JournalParser().parse(Self.oneSpace)
        #expect(journal.amountAlignment == .end(column: 45))
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

    /// hledger converts `@@ T` to the per-unit price `T / |quantity|`, so the
    /// cost is `T` with the quantity's sign on it and `T`'s own sign kept. All
    /// four combinations are pinned here because the conformance harness
    /// renders a total cost unsigned on both sides and would pass whatever
    /// sign this produced.
    @Test(arguments: [
        TotalCostCase(quantity: 100, total: 110, cost: 110),
        TotalCostCase(quantity: -100, total: 110, cost: -110),
        TotalCostCase(quantity: 100, total: -110, cost: -110),
        TotalCostCase(quantity: -100, total: -110, cost: 110),
    ])
    func `a total cost keeps the sign the journal wrote`(signs: TotalCostCase) {
        let price = PostingPrice.total(Amount(quantity: signs.total, commodity: "USD"))
        #expect(price.cost(of: signs.quantity) == Amount(quantity: signs.cost, commodity: "USD"))
    }

    /// One quantity, one written total, and the cost hledger makes of them.
    struct TotalCostCase {
        var quantity: Decimal
        var total: Decimal
        var cost: Decimal
    }

    /// The same rule read out of a file: a negative total is legal in hledger
    /// and this entry is one hledger loads, so it has to load here.
    @Test
    func `an entry priced with a negative total balances`() throws {
        let text = """
        2026-01-01 a
            assets:eur2    100 EUR @@ -110 USD
            assets:usd2    110 USD
        """
        let transaction = try #require(try JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].balancingAmount == Amount(quantity: -110, commodity: "USD"))
    }

    @Test
    func `an unbalanced priced transaction still throws`() throws {
        let text = """
        2024-01-01 Buy shares
            Assets:Brokerage  10 AAPL @ $150.00
            Assets:Checking   $-1000.00
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .unbalancedTransaction(residuals: [dollars(500)]))
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

// MARK: - JournalParser: comment blocks

@Suite("comment blocks") struct CommentBlockTests {
    private static let oneDollar = Amount(quantity: 1, commodity: "$", commodityIsPrefix: true)

    @Test
    func `a transaction inside a comment block is text, not data`() throws {
        let text = """
        comment
        scratch notes
        2024-01-01 not a transaction
            a  $1
            b  $-1
        end comment

        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(Ledger(journal: journal).balance(for: "a") == [Self.oneDollar])
        #expect(journal.directives == [
            "comment",
            "scratch notes",
            "2024-01-01 not a transaction",
            "    a  $1",
            "    b  $-1",
            "end comment",
        ])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `an unterminated block runs to the end of the file`() throws {
        let text = """
        comment
        scratch notes
        2024-01-02 swallowed
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.isEmpty)
        #expect(journal.directives == text.components(separatedBy: "\n"))
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `trailing whitespace on either keyword still marks the block`() throws {
        let text = "comment  \n"
            + "2024-01-01 not a transaction\n"
            + "end comment\t\n"
            + "\n"
            + "2024-01-02 real\n"
            + "    a  $1\n"
            + "    b  $-1"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == ["comment  ", "2024-01-01 not a transaction", "end comment\t"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `text after the keyword is ignored, as ledger ignores it`() throws {
        // ledger matches the first word of the line, so `comment notes` opens
        // a block. Reading it as a directive instead would book the entry
        // below it, which is the bug this suite is about.
        let text = """
        comment notes
        2024-01-02 parked
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.isEmpty)
        #expect(journal.directives == text.components(separatedBy: "\n"))
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a test line opens a block the same way comment does`() throws {
        let text = """
        test
        2024-01-01 not a transaction
            a  $1
            b  $-1
        end test

        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(Ledger(journal: journal).balance(for: "a") == [Self.oneDollar])
        #expect(journal.directives == [
            "test",
            "2024-01-01 not a transaction",
            "    a  $1",
            "    b  $-1",
            "end test",
        ])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `either end keyword closes either kind of block`() throws {
        // ledger reads one list of closing keywords, whichever keyword opened
        // the block, so a file that crosses them still parks its contents.
        let crossed = """
        comment
        2024-01-01 not a transaction
        end test
        test
        2024-01-02 not one either
        end comment

        2024-01-03 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(crossed)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == [
            "comment",
            "2024-01-01 not a transaction",
            "end test",
            "test",
            "2024-01-02 not one either",
            "end comment",
        ])
        #expect(JournalSerializer().serialize(journal) == crossed)
    }

    @Test
    func `an end keyword closes the block whatever follows it`() throws {
        let text = """
        comment
        2024-01-01 not a transaction
        end comment  ; back to real entries

        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == [
            "comment",
            "2024-01-01 not a transaction",
            "end comment  ; back to real entries",
        ])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `a longer word starting with the keyword opens nothing`() throws {
        // The keyword ends at whitespace, so `comments` is its own word and
        // its own directive, and what follows is data.
        let text = """
        comments
        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == ["comments"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `the keyword is case-sensitive`() throws {
        let text = """
        Comment
        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == ["Comment"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `an indented keyword neither opens nor closes a block`() throws {
        let indentedStart = """
            comment
        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(indentedStart)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(journal.directives == ["    comment"])
        #expect(JournalSerializer().serialize(journal) == indentedStart)

        // …and inside a block the same indentation leaves `end comment` as
        // content, so the transaction below it stays commented out.
        let indentedEnd = """
        comment
          end comment
        2024-01-02 not a transaction
            a  $1
            b  $-1
        """
        let blocked = try JournalParser().parse(indentedEnd)
        #expect(blocked.transactions.isEmpty)
        #expect(blocked.directives == indentedEnd.components(separatedBy: "\n"))
    }

    @Test
    func `a block teaches the parser no styles and declares no accounts`() throws {
        let text = """
        comment
        D $1,000.00
        account Assets:Imaginary
        end comment

        2024-01-02 real
            a  100.00 EUR
            b  -100.00 EUR
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["$"] == nil)
        #expect(journal.commodityFormats["EUR"] != nil)
        #expect(journal.accountDirectives.isEmpty)
        #expect(!Ledger(journal: journal).accounts.map(\.name).contains("Assets:Imaginary"))
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `blank lines inside a block survive a round-trip`() throws {
        let text = """
        comment

        scratch notes

        end comment

        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(Array(journal.items.prefix(5)) == [
            .directive("comment"),
            .blank,
            .directive("scratch notes"),
            .blank,
            .directive("end comment"),
        ])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `percent and pipe lines are comments, not directives`() throws {
        let text = """
        % a note in the hledger style
        | another one
        2024-01-02 real
            a  $1
            b  $-1
        """
        let journal = try JournalParser().parse(text)
        #expect(Array(journal.items.prefix(2)) == [
            .comment("% a note in the hledger style"),
            .comment("| another one"),
        ])
        #expect(journal.directives.isEmpty)
        #expect(journal.transactions.map(\.description) == ["real"])
        #expect(JournalSerializer().serialize(journal) == text)
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

    /// The account an opening-balances entry elides reports both commodities,
    /// because the elided line resolved into a posting in each. `balance(for:)`
    /// nets by commodity and sorts by the commodity symbol, which puts `$`
    /// before `£`.
    @Test
    func `balance reports every commodity an elided opening entry left to one account`() throws {
        let text = """
        2024-01-01 opening balances
            assets:bank:checking   $1000
            assets:bank:savings    £500
            equity:opening balances
        """
        let ledger = try Ledger(journal: JournalParser().parse(text))
        let balance = ledger.balance(for: "equity:opening balances")
        #expect(balance == [
            Amount(quantity: -1000, commodity: "$", commodityIsPrefix: true),
            Amount(quantity: -500, commodity: "£", commodityIsPrefix: true),
        ])
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

    /// An elided line that absorbed two commodities is still one line in the
    /// file, and a transaction nobody edited is written from the lines it was
    /// read from, so the expansion never reaches the file.
    @Test
    func `an elided posting that absorbed two commodities is written back as the one line it was`() throws {
        let text = """
        2024-01-01 opening balances
            assets:bank:checking   $1000
            assets:bank:savings    £500
            equity:opening balances
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.count == 4)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Rebuilding the transaction drops its source lines, so the entry is
    /// formatted afresh and the expansion does show: one line per commodity,
    /// the account name repeated, which is how hledger prints such an entry.
    /// What it prints reads back as the very postings it was written from.
    @Test
    func `a rebuilt multi-commodity elision is written as one line per commodity`() throws {
        let text = """
        2024-01-01 opening balances
            assets:bank:checking   $1000
            assets:bank:savings    £500
            equity:opening balances
        """
        var journal = try JournalParser().parse(text)
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
        let removed = journal.remove(.transaction(parsed))
        #expect(removed)
        journal.append(.transaction(rebuilt))

        let written = JournalSerializer().serialize(journal)
        let equityLines = written.components(separatedBy: "\n")
            .filter { $0.contains("equity:opening balances") }
        #expect(equityLines.count == 2)
        #expect(equityLines[0].hasSuffix("-$1000"))
        #expect(equityLines[1].hasSuffix("-£500"))

        let reparsed = try #require(try JournalParser().parse(written).transactions.first)
        #expect(reparsed.postings == rebuilt.postings)
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

/// Rebuilds `transaction` with a new description, in place, the way an edit
/// through `LedgerManager` used to — remove then append, so the source text
/// goes and the entry lands at the end of the file.
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

// MARK: - JournalSerializer: writing a rebuilt entry the way the file writes

/// `Decimal` forgets how a number was written. It normalises its own scale on
/// construction, and the marks the parser read the number by are gone with the
/// text, so an amount rebuilt through `Transaction.init` used to come back as
/// whatever `Decimal.description` printed: `$1,240.50` written as `$1240.5`,
/// `@ $150.00` as `@ $150`.
///
/// That was survivable while every save reformatted the whole file. Once an
/// untouched transaction started replaying its own source lines, it stopped
/// being: the reformatting landed on exactly the one entry the user edited, and
/// an edit to a payee showed up in the diff as a restyled amount.
@Suite("commodity display format") struct CommodityDisplayFormatTests {
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

// MARK: - Which characters the marks are written with

/// A number carries two marks, and which character plays which part is the
/// file's convention rather than the library's. Writing a rebuilt amount with
/// the other one restyles every figure in the entry the user edited, and in a
/// file carrying an hledger `commodity €1.000,00` declaration it writes a line
/// that tool then refuses to load (issue #27).
@Suite("decimal marks") struct DecimalMarkTests {
    /// The journal from the issue: an edit to the payee used to come back with
    /// every number in the entry respelled.
    private static let europeanJournal = """
    2024-01-01 opening
        assets:bank      €1.000,00
        equity:opening  €-1.000,00

    2024-01-02 groceries
        expenses:food       €12,50
        assets:bank        €-12,50
    """

    @Test
    func `an edited entry keeps the marks the rest of the file uses`() throws {
        var journal = try JournalParser().parse(Self.europeanJournal)
        #expect(journal.commodityFormats["€"]?.decimalMark == ",")
        #expect(journal.commodityFormats["€"]?.groupMark == ".")

        try renaming(#require(journal.transactions.first), to: "opening (revised)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("€1.000,00"))
        #expect(written.contains("€12,50"))
        #expect(!written.contains("€1,000.00"))

        // Read back in, the rebuilt entry is the same thousand it always was,
        // which is what writing it this way round is for.
        let reparsed = try JournalParser().parse(written)
        #expect(try #require(reparsed.transactions.last).postings.map(\.amount.quantity) == [1000, -1000])
    }

    @Test
    func `a rewritten entry in such a file is stable, so the next save changes nothing`() throws {
        let parser = JournalParser()
        let serializer = JournalSerializer()
        var journal = try parser.parse(Self.europeanJournal)
        try renaming(#require(journal.transactions.first), to: "opening (revised)", in: &journal)

        let once = serializer.serialize(journal)
        #expect(try serializer.serialize(parser.parse(once)) == once)
    }

    /// The other convention is not a special case: it is the default, and a
    /// file that writes it gets back exactly what it always got.
    @Test
    func `a file written with a point keeps the point`() throws {
        let text = """
        2026-01-05 * Rent
            Expenses:Rent      $1,000.00
            Assets:Checking   $-1,000.00
        """
        var journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["$"]?.decimalMark == ".")
        #expect(journal.commodityFormats["$"]?.groupMark == ",")
        #expect(CommodityFormat().decimalMark == ".")
        #expect(CommodityFormat().groupMark == ",")

        try renaming(#require(journal.transactions.first), to: "Rent (Jan)", in: &journal)
        #expect(JournalSerializer().serialize(journal).contains("$1,000.00"))
    }

    /// A file may be inconsistent, so the marks are counted like everything
    /// else the collector learns, and the count decides.
    @Test
    func `the mark most of the amounts use is the one a rebuilt amount gets`() throws {
        let text = """
        2026-01-01 opening
            assets:bank      100,50 EUR
            equity:opening  -100,50 EUR

        2026-01-02 groceries
            expenses:food     20,25 EUR
            assets:bank      -20,25 EUR

        2026-01-03 lunch
            expenses:food     10.75 EUR
            assets:bank      -10.75 EUR
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")
    }

    /// Ties go to the point, which is the default and what SwiftLedger has
    /// always written, so a file that says nothing clear is left as it was.
    @Test
    func `a file split evenly keeps the point`() throws {
        let text = """
        2026-01-01 opening
            assets:bank      100,50 EUR
            equity:opening  -100,50 EUR

        2026-01-02 lunch
            expenses:food     10.75 EUR
            assets:bank      -10.75 EUR
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ".")
    }

    /// `€1.000` could be a thousand grouped or one written to three places,
    /// and the scanner settles it by a rule rather than by anything the number
    /// says. A number read that way abstains here, so the file's one piece of
    /// real evidence is not outvoted by three pieces of none.
    @Test
    func `a number that cannot say which mark is which casts no vote`() throws {
        let commaFile = """
        2026-01-01 opening
            assets:bank      €1.000
            equity:opening  €-1.000

        2026-01-02 second
            assets:bank      €2.000
            equity:opening  €-2.000

        2026-01-03 third
            assets:bank      €3.000
            equity:opening  €-3.000

        2026-01-04 coffee
            expenses:food     €12,50
            assets:bank      €-12,50
        """
        #expect(try JournalParser().parse(commaFile).commodityFormats["€"]?.decimalMark == ",")

        let pointFile = """
        2026-01-01 opening
            assets:bank      $1,000
            equity:opening  $-1,000

        2026-01-02 second
            assets:bank      $2,000
            equity:opening  $-2,000

        2026-01-03 coffee
            expenses:food     $12.50
            assets:bank      $-12.50
        """
        #expect(try JournalParser().parse(pointFile).commodityFormats["$"]?.decimalMark == ".")
    }

    /// A file with no fraction anywhere still shows which convention it
    /// follows: the mark it groups with is the one it does not divide with.
    @Test
    func `a group mark alone says which mark divides`() throws {
        let text = """
        2026-01-01 opening
            assets:bank      1.000.000 EUR
            equity:opening  -1.000.000 EUR
        """
        var journal = try JournalParser().parse(text)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")
        #expect(journal.commodityFormats["EUR"]?.groupsThousands == true)

        try journal.append(.transaction(Transaction(
            date: makeDate(2026, 1, 2),
            description: "second",
            postings: [
                Posting(accountName: "assets:bank", amount: Amount(quantity: 2_000_000, commodity: "EUR")),
                Posting(accountName: "equity:opening", amount: Amount(quantity: -2_000_000, commodity: "EUR")),
            ],
        )))
        #expect(JournalSerializer().serialize(journal).contains("2.000.000 EUR"))
    }

    /// A declaration is the user stating their house style, so it settles the
    /// marks the way it settles the digit count, against whatever the amounts
    /// happen to show.
    @Test(arguments: [
        "D 1.000,00 EUR",
        "commodity 1.000,00 EUR",
        "commodity EUR\n    format 1.000,00 EUR",
    ])
    func `a directive states which mark divides`(directive: String) throws {
        var journal = try JournalParser().parse("""
        \(directive)

        2026-01-01 lunch
            expenses:food     12.50 EUR
            assets:bank      -12.50 EUR
        """)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")

        try renaming(#require(journal.transactions.first), to: "lunch (revised)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("12,50 EUR"))
        #expect(!written.contains("12.50 EUR"))
    }

    /// A declaration whose own sample cannot tell its marks apart declares a
    /// digit count and nothing else, and the amounts settle the rest.
    @Test
    func `a declaration that shows no mark leaves the marks to the amounts`() throws {
        var journal = try JournalParser().parse("""
        D 1.000 EUR

        2026-01-01 lunch
            expenses:food     12,50 EUR
            assets:bank      -12,50 EUR
        """)
        #expect(journal.commodityFormats["EUR"]?.decimalMark == ",")

        // Three places because the declaration says three, a comma because the
        // postings say comma, and a fourth place because the reader cannot
        // settle `12,500` and would hand back twelve thousand five hundred.
        try renaming(#require(journal.transactions.first), to: "lunch (revised)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("12,5000 EUR"))
        #expect(try #require(JournalParser().parse(written).transactions.last)
            .postings.map(\.amount.quantity) == [Decimal(string: "12.5"), Decimal(string: "-12.5")])
    }

    @Test
    func `rendering writes both marks the file's way round`() throws {
        let euros = CommodityFormat(fractionDigits: 2, groupsThousands: true, decimalMark: ",")
        #expect(try euros.render(#require(Decimal(string: "1234567.5"))) == "1.234.567,50")
        #expect(euros.render(1000) == "1.000,00")
        #expect(euros.render(999) == "999,00")

        let ungrouped = CommodityFormat(fractionDigits: 2, decimalMark: ",")
        #expect(try ungrouped.render(#require(Decimal(string: "1234.5"))) == "1234,50")
    }
}

// MARK: - What is written has to read back

/// Rendering and parsing are two halves of one round trip, and the parser
/// settles one shape by a tie-break rather than by anything the number says.
/// A writer that ignored that put a number on disk worth a thousand times what
/// it held: `12,125` came back grouped, and `1.000` came back divided.
@Suite("rendered marks read back") struct RenderedMarkTests {
    /// Every shape this type can write, read back as the value it held.
    @Test(arguments: [".", ","] as [Character], [false, true])
    func `every rendered amount parses back to the value it held`(
        mark: Character,
        groups: Bool,
    ) throws {
        let quantities: [Decimal] = try [
            0,
            1,
            #require(Decimal(string: "12.5")),
            #require(Decimal(string: "12.125")),
            #require(Decimal(string: "0.125")),
            1000,
            #require(Decimal(string: "1234.567")),
            1_000_000,
        ]
        for digits in 0 ... 4 {
            let format = CommodityFormat(fractionDigits: digits, groupsThousands: groups, decimalMark: mark)
            for quantity in quantities {
                let text = format.render(quantity)
                let suffixed = try JournalParser().parseAmount("\(text) EUR", lineNumber: 1)
                #expect(suffixed.quantity == quantity, "\(text) EUR")
                let prefixed = try JournalParser().parseAmount("€\(text)", lineNumber: 1)
                #expect(prefixed.quantity == quantity, "€\(text)")
            }
        }
    }

    /// An eighth of a euro in a file that writes two places: the third place
    /// is the amount's own, and the fourth is what keeps the comma from
    /// reading as a group mark on the way back in.
    @Test
    func `an amount with three places joins a comma file with four`() throws {
        var journal = try JournalParser().parse("""
        2024-01-02 groceries
            expenses:food       €12,50
            assets:bank        €-12,50
        """)
        let eighth = try #require(Decimal(string: "12.125"))
        try journal.append(.transaction(Transaction(
            date: makeDate(2024, 1, 3),
            description: "coffee",
            postings: [
                Posting(
                    accountName: "expenses:food",
                    amount: Amount(quantity: eighth, commodity: "€", commodityIsPrefix: true),
                ),
                Posting(
                    accountName: "assets:bank",
                    amount: Amount(quantity: -eighth, commodity: "€", commodityIsPrefix: true),
                ),
            ],
        )))

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("€12,1250"))
        let reparsed = try #require(JournalParser().parse(written).transactions.last)
        #expect(reparsed.postings.map(\.amount.quantity) == [eighth, -eighth])
    }

    /// A file that writes three places pads a shorter amount to three, which
    /// is exactly the shape the reader cannot settle, so it gets a fourth.
    @Test
    func `an amount padded to three places in a comma file gets a fourth`() throws {
        var journal = try JournalParser().parse("""
        2024-01-02 opening
            assets:bank      €1.234,567
            equity:opening  €-1.234,567
        """)
        #expect(journal.commodityFormats["€"]?.fractionDigits == 3)
        let half = try #require(Decimal(string: "12.5"))
        try journal.append(.transaction(Transaction(
            date: makeDate(2024, 1, 3),
            description: "coffee",
            postings: [
                Posting(
                    accountName: "expenses:food",
                    amount: Amount(quantity: half, commodity: "€", commodityIsPrefix: true),
                ),
                Posting(
                    accountName: "assets:bank",
                    amount: Amount(quantity: -half, commodity: "€", commodityIsPrefix: true),
                ),
            ],
        )))

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("€12,5000"))
        let reparsed = try #require(JournalParser().parse(written).transactions.last)
        #expect(reparsed.postings.map(\.amount.quantity) == [half, -half])
    }

    /// A thousand in a file that groups with `.` and writes no fraction: the
    /// grouping is what would make `1.000`, so that one number goes ungrouped,
    /// as every number under a thousand in the same file already is.
    @Test
    func `a thousand with no fraction is written ungrouped in a comma file`() throws {
        let format = CommodityFormat(fractionDigits: 0, groupsThousands: true, decimalMark: ",")
        #expect(format.render(1000) == "1000")
        #expect(format.render(999) == "999")
        // Two groups say what one cannot, and an amount with a fraction writes
        // both marks, so neither of those gives anything up.
        #expect(format.render(1_000_000) == "1.000.000")
        #expect(try CommodityFormat(fractionDigits: 2, groupsThousands: true, decimalMark: ",")
            .render(#require(Decimal(string: "1000.5"))) == "1.000,50")
    }
}

// MARK: - How many digits, and for whom

/// `fractionDigits` and `maxFractionDigits` answer different questions and have
/// different callers. A serializer that padded every amount to the largest
/// would turn a file of `$1,234.50` into one of `$1,234.500`; a display that
/// rounded every figure to the most common would turn a real `0.00123456 BTC`
/// holding into `BTC0.00`.
@Suite("commodity precision") struct CommodityPrecisionTests {
    @Test
    func `the digits a padded amount was written with survive the Decimal`() throws {
        let text = """
        2026-04-01 * Buy
            Assets:Crypto           0.50000000 BTC
            Assets:Exchange        -0.50000000 BTC
        """
        let journal = try JournalParser().parse(text)
        let posting = try #require(journal.transactions.first?.postings.first)

        // The model cannot answer this question: `Decimal` normalised eight
        // written digits down to one on the way in, and `0.50000000` and `0.5`
        // are the same value by the time anything downstream sees them.
        #expect(posting.amount.quantity.exponent == -1)
        #expect(journal.commodityFormats["BTC"]?.maxFractionDigits == 8)
    }

    @Test
    func `the usual count and the largest are recorded separately`() throws {
        let text = """
        2026-01-05 * Rent
            Expenses:Rent                             $2,400.00
            Assets:Checking                          $-2,400.00

        2026-01-20 * Groceries
            Expenses:Groceries                           $60.00
            Assets:Checking                             $-60.00

        2026-02-01 * Interest
            Expenses:Fees                                 $0.333
            Assets:Checking                              $-0.333
        """
        var journal = try JournalParser().parse(text)
        let format = try #require(journal.commodityFormats["$"])

        // Two questions, two answers. How should a rebuilt amount be written?
        // The way most of them are. How precisely does this file speak about
        // dollars? To three places, because one amount says so.
        #expect(format.fractionDigits == 2)
        #expect(format.maxFractionDigits == 3)

        // The serializer still writes the usual count: padding every amount to
        // the largest would turn this file into one of `$2,400.000`.
        try renaming(#require(journal.transactions.first), to: "Rent (Jan)", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(written.contains("$2,400.00"))
        #expect(!written.contains("$2,400.000"))
    }

    @Test
    func `a declaration can raise the largest count but never lower it`() throws {
        let raised = try JournalParser().parse("""
        D $1,000.00

        2026-02-01 * Rent
            Expenses:Rent      $2400
            Assets:Checking    $-2400
        """)
        // Nothing here writes a cent, but the user declared that dollars have
        // two, and a declaration is a statement about the commodity.
        #expect(raised.commodityFormats["$"]?.maxFractionDigits == 2)

        let kept = try JournalParser().parse("""
        D $1,000.00

        2026-02-01 * Interest
            Expenses:Fees       $0.333
            Assets:Checking    $-0.333
        """)
        // The file speaks to three places whatever the declaration says about
        // how to write one, and rounding a display to two would hide a figure.
        #expect(kept.commodityFormats["$"]?.fractionDigits == 2)
        #expect(kept.commodityFormats["$"]?.maxFractionDigits == 3)
    }
}

// MARK: - JournalSerializer: laying it out the way the file lays it out

/// Where a rebuilt entry's columns come from. Formatting its numbers correctly
/// is half of leaving a diff alone; the other half is not moving them.
@Suite("journal layout") struct JournalLayoutTests {
    /// A journal whose postings both start their amount at `column` — built
    /// rather than written out, so the margin is a fact of the fixture and not
    /// of how carefully the spaces were counted.
    private func journalWithMargin(_ column: Int = 29) -> String {
        func line(_ account: String, _ amount: String) -> String {
            let indented = "    " + account
            return indented + String(repeating: " ", count: column - indented.count) + amount
        }
        return [
            "2026-01-05 * Rent",
            line("Expenses:Rent", "$2,400.00"),
            line("Assets:Checking", "$-2,400.00"),
        ].joined(separator: "\n")
    }

    @Test
    func `a rebuilt entry is laid out at the file's margin, not the library's`() throws {
        var journal = try JournalParser().parse(journalWithMargin())
        #expect(journal.amountAlignment == .start(column: 29))
        try renaming(#require(journal.transactions.first), to: "Rent (Jan)", in: &journal)

        // Column 52 is a default, not a house style. Imposing it on the one
        // entry the user edited drags that entry's columns away from every
        // other entry's, which is a change nobody asked for.
        let postings = JournalSerializer().serialize(journal)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("    ") }
        #expect(postings.count == 2)
        for posting in postings {
            let dollar = try #require(posting.firstIndex(of: "$"))
            #expect(posting.distance(from: posting.startIndex, to: dollar) == 29)
        }
    }

    @Test
    func `a journal with no margin of its own keeps the library default`() throws {
        let transaction = try makeTx(date: makeDate(2026, 1, 1), description: "Coffee")
        let written = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        let posting = try #require(
            written.components(separatedBy: "\n").first { $0.hasPrefix("    Expenses") },
        )
        #expect(posting.dropFirst(52).hasPrefix("50 USD"))
    }

    @Test
    func `the most common margin wins, so one long account name is not the file`() throws {
        let text = """
        2026-01-05 * Rent
            Expenses:Rent                $2,400.00
            Assets:Checking              $-2,400.00

        2026-01-06 * Groceries
            Expenses:Food:Groceries:Bulk           $60.00
            Assets:Checking              $-60.00
        """
        // Three postings share a margin; the fourth is pushed out by its own
        // account name, and one long name is not the file's layout.
        #expect(try JournalParser().parse(text).amountAlignment == .start(column: 33))
    }
}

// MARK: - Replacing an item in place

/// Editing an entry used to mean removing it and appending its successor, which
/// tears it out of date order and leaves it at the end of the file: two changed
/// hunks for a one-field edit, neither of them where the reader is looking.
@Suite("replace in place") struct ReplaceInPlaceTests {
    /// `transaction` with a new description and nothing else changed.
    private func renamed(_ transaction: Transaction, to description: String) throws -> Transaction {
        try Transaction(
            id: transaction.id,
            date: transaction.date,
            auxDate: transaction.auxDate,
            status: transaction.status,
            code: transaction.code,
            description: description,
            postings: transaction.postings,
            comment: transaction.comment,
            leadingComments: transaction.leadingComments,
        )
    }

    @Test
    func `a replaced transaction stays where it was`() throws {
        var journal = try JournalParser().parse(handWrittenJournal)
        let groceries = try #require(journal.transactions.first)
        let replacement = try renamed(groceries, to: "Groceries (revised)")

        let replaced = journal.replace(.transaction(groceries), with: .transaction(replacement))
        #expect(replaced)
        #expect(journal.transactions.map(\.description) == [
            "Groceries (revised)", "Buy shares", "Salary",
        ])
        // The comment above it did not move either.
        #expect(journal.items.first == .comment("; a journal written by hand, not by SwiftLedger"))
    }

    @Test
    func `replacing something absent changes nothing and says so`() throws {
        var journal = try JournalParser().parse(handWrittenJournal)
        let before = journal.items
        let stranger = try makeTx(date: makeDate(1999, 1, 1))

        let replaced = journal.replace(.transaction(stranger), with: .transaction(stranger))
        #expect(!replaced)
        #expect(journal.items == before)
    }

    @Test
    func `the manager writes the replacement in place`() throws {
        let store = try InMemoryLedgerStore(
            ledger: Ledger(journal: JournalParser().parse(handWrittenJournal)),
        )
        let manager = try LedgerManager(store: store)
        let salary = try #require(manager.transactions().last)

        let replaced = try manager.replace(
            .transaction(salary), with: .transaction(renamed(salary, to: "Salary (adjusted)")),
        )
        #expect(replaced)
        #expect(manager.transactions().map(\.description) == [
            "Groceries", "Buy shares", "Salary (adjusted)",
        ])
    }

    /// A journal kept consistently: one indent, one margin, amounts ending at
    /// the same column, dollars written to two places with separators.
    ///
    /// `handWrittenJournal` cannot stand in for this. It is deliberately ragged
    /// — three different indents and four different margins — and a file with
    /// no house style has nothing for an edit to be consistent with.
    private static let tidyJournal: String = {
        func posting(_ account: String, _ amount: String) -> String {
            let indented = "    " + account
            return indented + String(repeating: " ", count: 34 - indented.count - amount.count) + amount
        }
        return ([
            "; household",
            "",
            "2026-01-05 * Rent",
            posting("Expenses:Rent", "$2,400.00"),
            posting("Assets:Checking", "$-2,400.00"),
            "",
            "2026-01-14 * Whole Foods",
            posting("Expenses:Groceries", "$1,240.50"),
            posting("Assets:Checking", "$-1,240.50"),
        ] as [String]).joined(separator: "\n")
    }()

    @Test
    func `a tidy journal is read as ending its amounts at one column`() throws {
        let journal = try JournalParser().parse(Self.tidyJournal)
        // Starts scatter by the width of each sign; ends agree. Four agreeing
        // ends beat two agreeing starts.
        #expect(journal.amountAlignment == .end(column: 34))
        #expect(journal.postingIndent == "    ")
    }

    @Test
    func `a replaced entry is the only line of the file that changes`() throws {
        var journal = try JournalParser().parse(Self.tidyJournal)
        let groceries = try #require(journal.transactions.last)
        try journal.replace(
            .transaction(groceries),
            with: .transaction(renamed(groceries, to: "Whole Foods Market")),
        )

        // The whole point, stated as a diff: same line count, one line apart.
        // Every other line — including the edited entry's own postings, which
        // were rebuilt and formatted rather than replayed — comes back byte
        // for byte.
        let before = Self.tidyJournal.components(separatedBy: "\n")
        let after = JournalSerializer().serialize(journal).components(separatedBy: "\n")
        #expect(before.count == after.count)
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(changed.map(\.offset) == [6])
        #expect(changed.first?.element.1 == "2026-01-14 * Whole Foods Market")
    }
}

// MARK: - Codable

@Suite("Codable") struct CodableTests {
    /// `Character` is not `Codable`, so the decimal mark is written and read
    /// by hand, as the one-character string a file writes it as.
    @Test
    func `a round-tripped commodity format keeps the mark it was written with`() throws {
        let format = CommodityFormat(fractionDigits: 2, groupsThousands: true, decimalMark: ",")
        let decoded = try JSONDecoder().decode(CommodityFormat.self, from: JSONEncoder().encode(format))
        #expect(decoded == format)
        #expect(decoded.decimalMark == ",")
        #expect(decoded.groupMark == ".")
    }

    /// Every format encoded before the mark existed was written by a version
    /// that wrote `.`, so that is what one decodes as, and an archive keeps the
    /// style it was made in.
    @Test
    func `a commodity format encoded before decimalMark existed still decodes`() throws {
        let json = """
        {"fractionDigits":2,"maxFractionDigits":2,
         "groupsThousands":true,"signPrecedesCommodity":false}
        """
        let format = try JSONDecoder().decode(CommodityFormat.self, from: Data(json.utf8))
        #expect(format.fractionDigits == 2)
        #expect(format.signPrecedesCommodity == false)
        #expect(format.decimalMark == ".")
        #expect(format.groupMark == ",")

        // A string that is not one character is not a mark either, and falls
        // back the same way.
        let empty = """
        {"fractionDigits":0,"maxFractionDigits":0,"groupsThousands":false,
         "signPrecedesCommodity":true,"decimalMark":""}
        """
        let decoded = try JSONDecoder().decode(CommodityFormat.self, from: Data(empty.utf8))
        #expect(decoded.decimalMark == ".")
    }

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
    func `a posting encoded before kind existed decodes as real`() throws {
        let json = """
        {"accountName":"Assets:Cash",
         "amount":{"quantity":5,"commodity":"USD","commodityIsPrefix":false}}
        """
        let posting = try JSONDecoder().decode(Posting.self, from: Data(json.utf8))
        #expect(posting.kind == .real)
        #expect(posting.delimitedAccountName == "Assets:Cash")
    }

    @Test
    func `a round-tripped posting keeps its kind`() throws {
        let posting = Posting(
            accountName: "Assets:Checking:Envelope:Food",
            kind: .balancedVirtual,
            amount: Amount(quantity: -10, commodity: "$", commodityIsPrefix: true),
        )
        let encoded = try JSONEncoder().encode(posting)
        // The raw value is the wire format, so Balance's sidecars can be read
        // by eye and by anything else that speaks this JSON.
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(text.contains(#""kind":"balancedVirtual""#))
        #expect(try JSONDecoder().decode(Posting.self, from: encoded) == posting)
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

    /// An envelope journal is a well-formed journal: the money a parenthesised
    /// posting moves is outside the double-entry books on purpose, so counting
    /// it here would read as unbalanced forever.
    @Test
    func `an unbalanced virtual posting does not make the journal unbalanced`() throws {
        let text = """
        2026-01-01 Set the reserve
            Expenses:Food        $10.00
            Assets:Cash         $-10.00
            (Reserve:capital)  $250,000
        """
        let ledger = try Ledger(journal: JournalParser().parse(text))
        let sheet = try BalanceSheet(ledger: ledger, asOf: makeDate(2026, 6, 1))
        #expect(sheet.isBalanced)
        #expect(ledger.balance(for: "Reserve:capital").map(\.quantity) == [250_000])
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

private func dollars(_ quantity: Decimal) -> Amount {
    Amount(quantity: quantity, commodity: "$", commodityIsPrefix: true)
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

// MARK: - Sparse entries

/// A journal holding the entries ledger and hledger accept and SwiftLedger
/// used to refuse outright: a dated line kept as a note, a lone posting of
/// zero, and a lone posting that elides its amount. Ordinary entries sit
/// around them, because the bug that mattered was one such line making the
/// whole file unreadable.
private let sparseEntryJournal = """
2024-01-01 Opening
    Assets:Checking          $1,000.00
    Equity:Opening          $-1,000.00

2024-01-05 rang the bank about the fee

2024-01-06 zero
    Assets:Savings   $0

2024-01-07 note
    Assets:Petty

2024-01-10 Coffee
    Expenses:Food                $4.00
    Assets:Checking             $-4.00
"""

@Suite("zero- and single-posting entries") struct SparseEntryTests {
    @Test
    func `a dated line on its own parses to a transaction with no postings`() throws {
        let journal = try JournalParser().parse("2024-01-01 just a payee")
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.isEmpty)
        #expect(transaction.description == "just a payee")
        #expect(transaction.date.description == "2024-01-01")
    }

    @Test
    func `a note parsed from a file is written back byte-for-byte`() throws {
        let text = "2024-01-01 just a payee"
        #expect(try JournalSerializer().serialize(JournalParser().parse(text)) == text)
    }

    @Test
    func `a postingless transaction built in code serialises as its header line alone`() throws {
        let transaction = try Transaction(
            date: makeDate(2024, 1, 1), description: "just a payee", postings: [],
        )
        #expect(transaction.sourceText == nil)
        let written = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        #expect(written == "2024-01-01 just a payee")
    }

    @Test
    func `a lone posting of zero parses, and its account is inferred`() throws {
        let journal = try JournalParser().parse("2024-01-01 zero\n    Assets:Checking   $0")
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.count == 1)
        #expect(transaction.postings[0].amount.quantity == 0)
        #expect(Ledger(journal: journal).accounts.map(\.name).contains("Assets:Checking"))
    }

    @Test
    func `a lone elided posting is read exactly as a written zero`() throws {
        let elided = try JournalParser().parse("2024-01-01 note\n    Assets:Petty")
        let written = try JournalParser().parse("2024-01-01 note\n    Assets:Petty  0")
        let elidedAmount = try #require(elided.transactions.first?.postings.first?.amount)
        let writtenAmount = try #require(written.transactions.first?.postings.first?.amount)
        #expect(elidedAmount.quantity == 0)
        #expect(elidedAmount == writtenAmount)
    }

    @Test
    func `a lone non-zero posting is rejected as unbalanced, never as empty`() throws {
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse("2024-01-01 oops\n    Assets:Checking   $5")
        }
        #expect(error.withoutLocation == .unbalancedTransaction(residuals: [dollars(5)]))
    }

    @Test
    func `a note and a lone zero posting leave every balance where it was`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(sparseEntryJournal))
        let checking = ledger.balance(for: "Assets:Checking")
        #expect(checking.count == 1)
        #expect(checking[0].quantity == 996)
        #expect(ledger.balance(for: "Assets:Savings").allSatisfy { $0.quantity == 0 })
        #expect(ledger.balance(for: "Assets:Petty").allSatisfy { $0.quantity == 0 })
        #expect(ledger.subtreeBalance(forPrefix: "Expenses")[0].quantity == 4)
    }

    @Test
    func `a statement for the zero account has one line and an unmoved running balance`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(sparseEntryJournal))
        let statement = AccountStatement(ledger: ledger, accountName: "Assets:Savings")
        #expect(statement.lines.count == 1)
        #expect(statement.lines[0].transaction.description == "zero")
        #expect(statement.lines[0].runningBalance.count == 1)
        #expect(statement.lines[0].runningBalance[0].quantity == 0)
    }

    @Test
    func `an unrelated add leaves the note and the sparse postings byte-for-byte`() throws {
        var journal = try JournalParser().parse(sparseEntryJournal)
        journal.append(.blank)
        try journal.append(.transaction(makeTx(date: makeDate(2024, 2, 1), description: "Lunch")))
        let written = JournalSerializer().serialize(journal)
        #expect(written.hasPrefix(sparseEntryJournal))
        #expect(written.contains("2024-01-05 rang the bank about the fee"))
        #expect(written.contains("    Assets:Savings   $0"))
        #expect(written.contains("    Assets:Petty\n"))
        #expect(written.contains("2024-02-01 Lunch"))
    }
}

// MARK: - Virtual postings

/// hledger's own mixed example: all three kinds of posting in one entry, the
/// two balancing groups sitting side by side.
private let envelopeJournal = """
2022-01-01 buy food with cash, update budget envelope subaccounts, & something else
  assets:cash                    $-10  ; <- these balance each other
  expenses:food                    $7  ; <-
  expenses:food                    $3  ; <-
  [assets:checking:budget:food]  $-10  ;   <- and these balance each other
  [assets:checking:available]     $10  ;   <-
  (something:else)                 $5  ;     <- this is not required to balance
"""

/// The entry from the bug report: nothing but parenthesised postings, which
/// hledger reads and SwiftLedger used to refuse as unbalanced by $550,000.
private let reserveJournal = """
2025-01-01 set the reserves
    (Reserve:capital)   $250,000
    (Reserve:launch)    $300,000
"""

/// A one-entry journal whose amounts all begin at `column` — built rather than
/// typed out, so the margin is a fact of the fixture and not of how carefully
/// the spaces were counted.
private func journalAligned(
    at column: Int,
    _ rows: [(account: String, amount: String)],
    payee: String = "Reserve and envelope",
) -> String {
    var lines = ["2026-01-05 " + payee]
    for row in rows {
        let indented = "    " + row.account
        lines.append(indented + String(repeating: " ", count: column - indented.count) + row.amount)
    }
    return lines.joined(separator: "\n")
}

private let allVirtualRows = [
    (account: "(Reserve:capital)", amount: "$250.00"),
    (account: "[Assets:Envelope]", amount: "$-60.00"),
    (account: "[Assets:Available]", amount: "$60.00"),
]

private let mixedMarginRows = [
    (account: "Expenses:Food", amount: "$60.00"),
    (account: "Assets:Checking", amount: "$-60.00"),
    (account: "[Assets:Envelope]", amount: "$-60.00"),
    (account: "[Assets:Available]", amount: "$60.00"),
]

@Suite("virtual postings") struct VirtualPostingTests {
    @Test
    func `parentheses make a posting virtual and the name bare`() throws {
        let journal = try JournalParser().parse(reserveJournal)
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.map(\.kind) == [.virtual, .virtual])
        #expect(transaction.postings.map(\.accountName) == ["Reserve:capital", "Reserve:launch"])
    }

    @Test
    func `brackets make a posting balanced virtual and the name bare`() throws {
        let text = """
        2026-09-01 Set aside
            [Reserve:Emergency]     $200.00
            [Reserve:Unallocated]  $-200.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.kind) == [.balancedVirtual, .balancedVirtual])
        #expect(transaction.postings.map(\.accountName) == ["Reserve:Emergency", "Reserve:Unallocated"])
    }

    @Test
    func `the reserve entry that would not load now loads`() throws {
        let journal = try JournalParser().parse(reserveJournal)
        #expect(journal.transactions.count == 1)
        let ledger = Ledger(journal: journal)
        #expect(ledger.balance(for: "Reserve:capital").map(\.quantity) == [250_000])
        #expect(ledger.balance(for: "Reserve:launch").map(\.quantity) == [300_000])
    }

    /// The other half of the same reading, and the one that costs somebody
    /// something: a journal that spelled an ordinary account `(Reserve:capital)`
    /// loaded before, because both legs were real and netted to zero. The
    /// parenthesised leg is out of the real group now, so the entry is $5
    /// short and the file refuses to load. hledger reads such a file the same
    /// way, which is why the reading wins over the compatibility. It is still
    /// a change to a file that used to parse, and the README says so.
    @Test(arguments: ["(Reserve:capital)", "[Envelope:Food]"])
    func `an entry that balanced only through a literal delimited name now throws`(
        account: String,
    ) throws {
        let text = """
        2026-01-01 old file
            \(account)   $5.00
            Assets:Cash        $-5.00
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .unbalancedTransaction(residuals: [dollars(-5)]))
    }

    @Test
    func `hledger's mixed entry reads as three kinds of posting`() throws {
        let journal = try JournalParser().parse(envelopeJournal)
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings.map(\.kind) == [
            .real, .real, .real, .balancedVirtual, .balancedVirtual, .virtual,
        ])
        #expect(transaction.postings.map(\.accountName) == [
            "assets:cash", "expenses:food", "expenses:food",
            "assets:checking:budget:food", "assets:checking:available", "something:else",
        ])
        let ledger = Ledger(journal: journal)
        #expect(ledger.balance(for: "assets:checking:budget:food").map(\.quantity) == [-10])
        #expect(ledger.balance(for: "something:else").map(\.quantity) == [5])
    }

    @Test
    func `real postings that do not sum to zero still throw unbalancedTransaction`() throws {
        let text = """
        2026-01-01 oops
            Expenses:Food        $70.00
            Assets:Cash         $-50.00
            (Reserve:capital)     $5.00
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .unbalancedTransaction(residuals: [dollars(20)]))
    }

    @Test
    func `bracketed postings that do not sum to zero throw their own error`() throws {
        let text = """
        2026-01-01 oops
            Expenses:Food        $10.00
            Assets:Cash         $-10.00
            [Envelope:Food]     $-15.00
            [Envelope:Free]      $20.00
        """
        let error = LedgerError.unbalancedBracketedPostings(residuals: [dollars(5)])
        let thrown = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(thrown.withoutLocation == error)

        // The case says which group is off and by how much in every commodity
        // it is off in, and is never mistaken for the real group's error.
        #expect(error == LedgerError.unbalancedBracketedPostings(residuals: [dollars(5)]))
        #expect(error != LedgerError.unbalancedBracketedPostings(residuals: [usd(5)]))
        #expect(error != LedgerError.unbalancedBracketedPostings(residuals: [dollars(6)]))
        #expect(error != LedgerError.unbalancedTransaction(residuals: [dollars(5)]))
        #expect(error.errorDescription == "Balanced virtual postings are off by $5")
    }

    @Test
    func `a parenthesised posting is never checked, whatever it holds`() throws {
        let text = """
        2026-01-01 Set the reserve
            Expenses:Food        $10.00
            Assets:Cash         $-10.00
            (Reserve:capital)  $1,000,000
        """
        let ledger = try Ledger(journal: JournalParser().parse(text))
        #expect(ledger.balance(for: "Reserve:capital").map(\.quantity) == [1_000_000])
    }

    @Test
    func `a status marker may precede the delimiter`() throws {
        let text = """
        2026-01-01 Coffee
            Expenses:Food       $5.00
            Assets:Cash        $-5.00
            * (Reserve:capital)  $5
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        let reserve = transaction.postings[2]
        #expect(reserve.status == .cleared)
        #expect(reserve.kind == .virtual)
        #expect(reserve.accountName == "Reserve:capital")
    }

    @Test(arguments: ["[Reserve:capital", "(Reserve:capital]"])
    func `an unmatched bracket stays part of the account name`(token: String) throws {
        let text = """
        2026-01-01 unmatched
            \(token)  $5.00
            Assets:Cash        $-5.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].kind == .real)
        #expect(transaction.postings[0].accountName == token)
    }

    @Test
    func `parentheses inside a name stay part of it`() throws {
        let text = """
        2026-01-01 Sold the old car
            Assets:Car (old)   $5.00
            Assets:Cash       $-5.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[0].kind == .real)
        #expect(transaction.postings[0].accountName == "Assets:Car (old)")
    }

    @Test
    func `an empty pair of delimiters is an ordinary name`() throws {
        let transaction = try #require(
            JournalParser().parse("2026-01-01 empty\n    ()  $0").transactions.first,
        )
        #expect(transaction.postings[0].kind == .real)
        #expect(transaction.postings[0].accountName == "()")
    }

    @Test
    func `space inside the delimiters is padding, not part of the name`() throws {
        var journal = try JournalParser().parse("2026-01-01 padded\n    ( Reserve:capital )  $5.00")
        let transaction = try #require(journal.transactions.first)
        #expect(transaction.postings[0].kind == .virtual)
        #expect(transaction.postings[0].accountName == "Reserve:capital")

        try renaming(transaction, to: "padded, then rebuilt", in: &journal)
        #expect(JournalSerializer().serialize(journal).contains("(Reserve:capital)"))
    }

    @Test
    func `a price and a balance assertion survive on a virtual posting`() throws {
        let text = """
        2026-01-01 Envelope and shares
            [Assets:Envelope]   $-10.00 = $90.00
            [Assets:Available]   $10.00
            (Reserve:Shares)    10 AAPL @ $150.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        let asserted = Amount(quantity: 90, commodity: "$", commodityIsPrefix: true)
        #expect(transaction.postings[0].balanceAssertion == asserted)
        #expect(transaction.postings[2].kind == .virtual)
        #expect(transaction.postings[2].price == .perUnit(
            Amount(quantity: 150, commodity: "$", commodityIsPrefix: true),
        ))
        #expect(transaction.postings[2].balancingAmount.quantity == 1500)
    }

    @Test
    func `a priced bracketed posting balances at its cost`() throws {
        func entry(_ cash: String) -> String {
            """
            2026-01-01 Envelope buys shares
                [Assets:Envelope:Shares]  10 AAPL @ $150.00
                [Assets:Envelope:Cash]    \(cash)
            """
        }
        let transaction = try #require(JournalParser().parse(entry("$-1,500.00")).transactions.first)
        #expect(transaction.postings[0].balancingAmount.quantity == 1500)

        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(entry("$-1,400.00"))
        }
        #expect(error.withoutLocation == .unbalancedBracketedPostings(residuals: [dollars(100)]))
    }
}

// MARK: - Virtual postings and elided amounts

/// One missing amount per balancing group, and none inferable for a
/// parenthesised posting — the rule hledger states and the one place ledger-cli
/// would answer differently.
@Suite("virtual posting elision") struct VirtualPostingElisionTests {
    /// The parenthesised leg is what makes this a test rather than a reading:
    /// the bracketed pair nets to zero and so would leave the answer alone
    /// either way, but a remainder taken over the whole entry would hand
    /// `Assets:Checking` the reserve's $5 as well and answer -65.
    @Test
    func `an elided real posting balances the real group alone`() throws {
        let text = """
        2026-01-01 Groceries
            Expenses:Food                $60.00
            Assets:Checking
            [Assets:Checking:Envelope]  $-25.00
            [Assets:Checking:Free]       $25.00
            (Reserve:capital)             $5.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[1].amount.quantity == -60)
        #expect(transaction.postings[1].amount.commodity == "$")
    }

    /// Mirror of the above, and the parenthesised leg earns its place the same
    /// way: over the whole entry the remainder would be 20, not 25.
    @Test
    func `an elided bracketed posting balances the bracketed group alone`() throws {
        let text = """
        2026-01-01 Groceries
            Expenses:Food                $60.00
            Assets:Checking             $-60.00
            [Assets:Checking:Envelope]  $-25.00
            [Assets:Checking:Free]
            (Reserve:capital)             $5.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings[3].amount.quantity == 25)
        #expect(transaction.postings[3].kind == .balancedVirtual)
    }

    @Test
    func `each group may elide one amount in the same entry`() throws {
        let text = """
        2026-01-01 Groceries
            Expenses:Food                $60.00
            Assets:Checking
            [Assets:Checking:Envelope]  $-45.00
            [Assets:Checking:Free]
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.amount.quantity) == [60, -60, -45, 45])
    }

    @Test(arguments: [
        "    Expenses:Food   $60.00\n    Assets:Checking\n    Assets:Savings",
        "    [Envelope:Food]  $-60.00\n    [Envelope:Free]\n    [Envelope:Other]",
    ])
    func `two elided postings in one balancing group throw multipleElidedPostings`(
        postings: String,
    ) throws {
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse("2026-01-01 oops\n" + postings)
        }
        #expect(error.withoutLocation == .multipleElidedPostings)
    }

    @Test
    func `an elided parenthesised posting reads as zero and takes nothing from the rest`() throws {
        let text = """
        2026-01-01 Coffee
            Expenses:Food       $4.00
            Assets:Cash        $-4.00
            (Reserve:capital)
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.amount.quantity) == [4, -4, 0])
        #expect(transaction.postings[2].kind == .virtual)
    }

    /// hledger leaves such an amount missing; SwiftLedger's stand-in is a zero,
    /// and it has to be a zero in the commodity the entry is written in. Taking
    /// the library's fallback instead would answer `0 USD` for a dollar journal
    /// and write `0 USD` into it on the next rebuild.
    @Test
    func `an elided parenthesised posting keeps the entry's own commodity`() throws {
        let text = """
        2026-01-01 Coffee
            Expenses:Food       $4.00
            Assets:Cash        $-4.00
            (Reserve:capital)
        """
        var journal = try JournalParser().parse(text)
        let reserve = try #require(Ledger(journal: journal).balance(for: "Reserve:capital").first)
        #expect(reserve.commodity == "$")
        #expect(reserve.commodityIsPrefix)
        #expect(reserve.quantity == 0)

        try renaming(#require(journal.transactions.first), to: "Coffee and a reserve", in: &journal)
        let written = JournalSerializer().serialize(journal)
        #expect(!written.contains("USD"))
        #expect(written.contains("(Reserve:capital)"))
    }

    /// The change this commit makes to a file that already parsed: a written
    /// `(…)` amount used to be part of the one remainder every elision was
    /// computed from, so `Assets:Petty` came back -$5. The parenthesised leg is
    /// in no group now, the real group is empty, and an empty group leaves
    /// zero, in the entry's own commodity, which only the reserve wrote.
    @Test
    func `a written parenthesised amount does not feed a real elision`() throws {
        let text = """
        2026-01-07 note
            Assets:Petty
            (Reserve:capital)  $5.00
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.kind) == [.real, .virtual])
        #expect(transaction.postings.map(\.amount.quantity) == [0, 5])
        #expect(transaction.postings[0].amount.commodity == "$")
    }

    /// In an entry written in one commodity, "the entry's commodity" is not
    /// ambiguous. In one written in two it is the first amount *in file
    /// order*, whichever group wrote it. Pinned here so that a reordering
    /// changing the answer is a decision somebody made and not a surprise.
    @Test
    func `an elided parenthesised posting takes the first commodity in file order`() throws {
        let text = """
        2026-01-01 mixed
            Assets:Savings      10 EUR
            Assets:Checking    -10 EUR
            [Envelope:One]       $5.00
            [Envelope:Two]      $-5.00
            (Reserve:capital)
        """
        let reserve = try #require(JournalParser().parse(text).transactions.first?.postings.last)
        #expect(reserve.amount.quantity == 0)
        #expect(reserve.amount.commodity == "EUR")
    }

    /// The commodity a price is written in never wins: the zero is taken from
    /// what the first posting *moved*, not from what it cost. So a share
    /// purchase hands an elided parenthesised leg `AAPL`, and that is the
    /// commodity a rebuild writes into the file.
    @Test
    func `an elided parenthesised posting takes the moved commodity, not the priced one`() throws {
        let text = """
        2026-01-01 shares
            Assets:Brokerage   10 AAPL @ $150.00
            Assets:Cash       $-1,500.00
            (Reserve:units)
        """
        var journal = try JournalParser().parse(text)
        let entry = try #require(journal.transactions.first)
        let reserve = try #require(entry.postings.last)
        #expect(reserve.amount.quantity == 0)
        #expect(reserve.amount.commodity == "AAPL")
        #expect(!reserve.amount.commodityIsPrefix)

        try renaming(entry, to: "shares and a reserve", in: &journal)
        #expect(JournalSerializer().serialize(journal).contains("0 AAPL"))
    }

    @Test
    func `any number of parenthesised postings may elide their amounts`() throws {
        let text = """
        2026-01-01 Coffee
            Expenses:Food       $4.00
            Assets:Cash        $-4.00
            (Reserve:capital)
            (Reserve:launch)
        """
        let transaction = try #require(JournalParser().parse(text).transactions.first)
        #expect(transaction.postings.map(\.amount.quantity) == [4, -4, 0, 0])
        #expect(transaction.postings.suffix(2).allSatisfy { $0.kind == .virtual })
    }
}

// MARK: - Virtual postings on the page

/// Where a virtual posting sits in a file: the delimiters the parser measured
/// the margin through, and the ones the serializer has to put back.
@Suite("virtual postings in a file") struct VirtualPostingFileTests {
    @Test(arguments: [envelopeJournal, reserveJournal])
    func `a journal of virtual postings is written back byte-for-byte`(text: String) throws {
        #expect(try JournalSerializer().serialize(JournalParser().parse(text)) == text)
    }

    @Test
    func `a rebuilt entry writes the delimiters back at the file's margin`() throws {
        var journal = try JournalParser().parse(journalAligned(at: 29, allVirtualRows))
        try renaming(#require(journal.transactions.first), to: "Reserve and envelope, edited", in: &journal)

        let postings = JournalSerializer().serialize(journal)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("    ") }
        #expect(postings.count == 3)
        #expect(postings[0].hasPrefix("    (Reserve:capital)"))
        #expect(postings[1].hasPrefix("    [Assets:Envelope]"))
        #expect(postings[2].hasPrefix("    [Assets:Available]"))
        for posting in postings {
            let dollar = try #require(posting.firstIndex(of: "$"))
            #expect(posting.distance(from: posting.startIndex, to: dollar) == 29)
        }
    }

    @Test
    func `a rebuilt posting writes its status marker before the delimiters`() throws {
        let transaction = try Transaction(
            date: makeDate(2026, 1, 1), description: "Reserve",
            postings: [
                Posting(
                    accountName: "Reserve:capital",
                    kind: .virtual,
                    amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true),
                    status: .cleared,
                ),
            ],
        )
        let written = JournalSerializer().serialize(Journal(items: [.transaction(transaction)]))
        let posting = try #require(written.components(separatedBy: "\n").last)
        #expect(posting.hasPrefix("    * (Reserve:capital)  "))
        #expect(posting.hasSuffix("$5.00"))
    }

    /// Regression: the margin was read by searching the line for the account
    /// name, which for a bare name lands inside the parentheses and answers
    /// `nil`. Every posting here is virtual, so a file that taught the
    /// collector nothing would fall back to the library's own column 52.
    @Test
    func `the amount column is observed through the delimiters`() throws {
        let journal = try JournalParser().parse(journalAligned(at: 29, allVirtualRows))
        #expect(journal.amountAlignment == .start(column: 29))
    }

    @Test
    func `real and virtual lines sharing a margin agree on it`() throws {
        let text = journalAligned(at: 33, mixedMarginRows, payee: "Groceries and the envelope")
        #expect(try JournalParser().parse(text).amountAlignment == .start(column: 33))
    }

    @Test
    func `a virtual account is listed under its bare name`() throws {
        let reserve = try Ledger(journal: JournalParser().parse(reserveJournal))
        #expect(reserve.accounts.map(\.name).contains("Reserve:capital"))

        let envelope = try Ledger(journal: JournalParser().parse(envelopeJournal))
        let names = envelope.accounts.map(\.name)
        #expect(names.contains("assets:checking:budget:food"))
        #expect(!names.contains { $0.hasPrefix("[") })
        let budgetFood = try #require(
            envelope.accounts.first { $0.name == "assets:checking:budget:food" },
        )
        #expect(budgetFood.type == .asset)
    }

    /// Queries and reports include virtual postings, which is hledger's
    /// default; leaving them out is a query option (`--real`) that does not
    /// exist here yet.
    @Test
    func `reports count a bracketed posting like any other`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(envelopeJournal))
        let statement = IncomeStatement(ledger: ledger)
        let food = try #require(statement.expenses.first { $0.account.name == "expenses:food" })
        #expect(food.amounts.map(\.quantity) == [10])

        let sheet = try BalanceSheet(ledger: ledger, asOf: makeDate(2026, 1, 1))
        let budgeted = try #require(
            sheet.assets.first { $0.account.name == "assets:checking:budget:food" },
        )
        #expect(budgeted.amounts.map(\.quantity) == [-10])
        #expect(sheet.assets.contains { $0.account.name == "assets:checking:available" })
    }
}

@Suite("written scale") struct WrittenScaleTests {
    private static let journal = """
    2026-01-01 Card payment abroad
        Expenses:Travel    1.00 EUR @ $1.0900
        Liabilities:Card   $-1.09

    2026-01-02 Opening balances
        Assets:Checking    $1000
        Assets:Savings     £500.000
        Equity:Opening
    """

    private func postings(of index: Int) throws -> [Posting] {
        let journal = try JournalParser().parse(Self.journal)
        return journal.transactions[index].postings
    }

    /// `Decimal` normalises its own scale, so the digits the file wrote are
    /// gone by the time a caller holds the amount. This is where they are
    /// kept, and what the balancing tolerance is read from.
    @Test
    func `the parser records the digits each amount was written with`() throws {
        #expect(try postings(of: 0).map(\.amountScale) == [2, 2])
        #expect(try postings(of: 1).map(\.amountScale) == [0, 3, nil, nil])
    }

    /// A rate is written to more places than the currency it prices, so it is
    /// recorded apart from the amount: it never tightens a commodity the entry
    /// writes a plain amount in.
    @Test
    func `a price's digits are recorded apart from the amount's`() throws {
        #expect(try postings(of: 0).map(\.priceScale) == [4, nil])
    }

    /// An elided line wrote no digits, so its fill has no scale to report,
    /// however many commodities it absorbed.
    @Test
    func `an inferred amount has no written scale`() throws {
        let filled = try postings(of: 1).suffix(2)
        #expect(filled.allSatisfy { $0.amountScale == nil })
        #expect(filled.map(\.amount.commodity) == ["$", "£"])
    }

    /// A posting built in code has never been written anywhere, so it reports
    /// nothing rather than guessing at two decimal places.
    @Test
    func `a posting built in code has no written scale`() {
        let posting = Posting(
            accountName: "Assets:Checking",
            amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true),
        )
        #expect(posting.amountScale == nil)
        #expect(posting.priceScale == nil)
    }

    /// The scales are typography, not content. A caller comparing a parsed
    /// posting with the one it rebuilt, which is what an edit re-anchoring
    /// itself and a conflict merge both do, must not start missing matches
    /// because the file typed `$1.00` where the rebuild holds `$1`.
    @Test
    func `the written scale takes no part in equality or hashing`() throws {
        let parsed = try #require(postings(of: 0).last)
        let rebuilt = Posting(
            accountName: parsed.accountName,
            amount: parsed.amount,
        )
        #expect(parsed.amountScale == 2)
        #expect(rebuilt.amountScale == nil)
        #expect(parsed == rebuilt)
        #expect(Set([parsed, rebuilt]).count == 1)
    }

    @Test
    func `the written scale is not encoded`() throws {
        let parsed = try #require(postings(of: 0).first)
        let data = try JSONEncoder().encode(parsed)
        let decoded = try JSONDecoder().decode(Posting.self, from: data)
        #expect(decoded.amountScale == nil)
        #expect(decoded.priceScale == nil)
        #expect(decoded == parsed)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Scale"))
    }
}

@Suite("balancing tolerance") struct BalancingToleranceTests {
    /// `1.00 EUR @ $1.0851` costs $1.0851, so a cash leg written to the cent
    /// leaves $0.0049 over. hledger loads that and SwiftLedger has to.
    @Test
    func `a residual too small to write balances`() throws {
        let journal = try JournalParser().parse("""
        2026-01-01 Card payment abroad
            Expenses:Travel    1.00 EUR @ $1.0851
            Liabilities:Card   $-1.09
        """)
        #expect(journal.transactions.count == 1)
    }

    /// Half of the last place written, the boundary included. Both entries
    /// write their dollars to two places, so 0.0050 is in and 0.0051 is out.
    @Test(arguments: [(rate: "1.100050", loads: true), (rate: "1.100051", loads: false)])
    func `the boundary is half of the last place written`(scenario: (rate: String, loads: Bool)) {
        let text = """
        2026-01-01 Exchange
            assets:eur          100 EUR @ \(scenario.rate) USD
            assets:usd      -110.00 USD
        """
        let journal = try? JournalParser().parse(text)
        #expect((journal != nil) == scenario.loads)
    }

    /// One posting written to four places tightens the whole entry, and it
    /// does so from either balancing group: that is how hledger 1.52.4 reads
    /// it, measured on the binary.
    @Test(arguments: ["    assets:usd2     1.0000 USD\n    assets:usd3    -1.0000 USD",
                      "    [budget:a]      1.0000 USD\n    [budget:b]     -1.0000 USD"])
    func `a posting written to more places tightens the entry`(extra: String) throws {
        let loose = """
        2026-01-01 Exchange
            assets:eur          100 EUR @ 1.100040 USD
            assets:usd      -110.00 USD
        """
        #expect(try JournalParser().parse(loose).transactions.count == 1)
        #expect(throws: LedgerError.self) { try JournalParser().parse(loose + "\n" + extra) }
    }

    /// A rate and an assertion are not amounts the entry claims to hold, so
    /// neither tightens a commodity the entry writes a plain amount in.
    @Test
    func `a rate and an assertion do not tighten the entry`() throws {
        let journal = try JournalParser().parse("""
        2026-01-01 Exchange
            assets:eur           100 EUR @ 1.100040 USD
            assets:usd       -110.00 USD = -110.0000 USD
        """)
        #expect(journal.transactions.count == 1)
    }

    /// A commodity the entry reaches only through a price has no amount to be
    /// measured by, so its rates are what set the boundary. Written to three
    /// places, 0.0005 is in and 0.004 is out.
    @Test(arguments: [(rate: "1.201", loads: true), (rate: "1.204", loads: false)])
    func `a commodity written only as a price is measured by its rates`(
        scenario: (rate: String, loads: Bool),
    ) {
        let text = """
        2026-01-01 Exchange
            a     0.5 EUR @ 1.200 USD
            b    -0.5 EUR @ \(scenario.rate) USD
        """
        let journal = try? JournalParser().parse(text)
        #expect((journal != nil) == scenario.loads)
    }

    /// A `commodity` directive states how to display an amount. Under
    /// hledger's default balancing it does not move this boundary, and the
    /// conformance journal `precision-balancing` is the same case read
    /// against the binary.
    @Test
    func `a commodity directive does not tighten the entry`() throws {
        let journal = try JournalParser().parse("""
        commodity 1000.000000 USD

        2026-01-01 Exchange
            assets:eur          100 EUR @ 1.100040 USD
            assets:usd      -110.00 USD
        """)
        #expect(journal.transactions.count == 1)
    }

    // MARK: - An amount nobody has written yet

    private static let fourPlaceJournal = """
    2026-01-01 Opening
        Assets:Checking     $1.0000
        Equity:Opening     $-1.0000
    """

    private static let twoPlaceJournal = """
    2026-01-01 Opening
        Assets:Checking     $1.00
        Equity:Opening     $-1.00
    """

    /// The entry from the first test, built in code instead of read: the same
    /// $0.0049 residual against a cash leg with no written form at all.
    private static func roundingEntry() throws -> Transaction {
        try Transaction(
            date: makeDate(2026, 1, 2), description: "Card payment abroad",
            postings: [
                Posting(
                    accountName: "Expenses:Travel",
                    amount: Amount(quantity: 1, commodity: "EUR"),
                    price: .perUnit(Amount(
                        quantity: #require(Decimal(string: "1.0851")),
                        commodity: "$",
                        commodityIsPrefix: true,
                    )),
                ),
                Posting(
                    accountName: "Liabilities:Card",
                    amount: Amount(
                        quantity: #require(Decimal(string: "-1.09")),
                        commodity: "$",
                        commodityIsPrefix: true,
                    ),
                ),
            ],
        )
    }

    private static func manager(over text: String) throws -> (LedgerManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tolerance-\(UUID().uuidString).ledger")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try (LedgerManager(store: PlainTextJournalStore(url: url)), url)
    }

    /// With no journal to consult, `Transaction.init` holds an amount to the
    /// digits the default style would write it with, which for `$` is two.
    @Test
    func `a transaction built in code is weighed in the default style`() throws {
        #expect(throws: Never.self) { try Self.roundingEntry() }
    }

    /// The journal the entry is being saved into writes its dollars to four
    /// places, so the cash leg will reach the file as `$-1.0900` and the next
    /// parse will hold the entry to a hundredth of a cent. Accepting it here
    /// would be writing a file SwiftLedger itself could not open.
    @Test
    func `add refuses an entry this journal would write in a shape it cannot read`() throws {
        let (manager, url) = try Self.manager(over: Self.fourPlaceJournal)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = try #require(throws: LedgerError.self) {
            try manager.add(.transaction(Self.roundingEntry()))
        }
        guard case let .unbalancedTransaction(residuals) = error else {
            Issue.record("expected an unbalanced transaction, got \(error)")
            return
        }
        #expect(residuals.map(\.commodity) == ["$"])
    }

    /// The same entry into a journal that writes its dollars to the cent: it
    /// is accepted, and what comes out of the save loads again. This is the
    /// round trip the whole written-scale machinery exists for.
    @Test
    func `what add accepts, the parser reads back`() throws {
        let (manager, url) = try Self.manager(over: Self.twoPlaceJournal)
        defer { try? FileManager.default.removeItem(at: url) }
        try manager.add(.transaction(Self.roundingEntry()))

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("$-1.09"))
        let reparsed = try JournalParser().parse(written)
        #expect(reparsed.transactions.count == 2)
    }

    /// A transaction still carrying its own source lines is replayed from
    /// them, so it is weighed as it was written rather than as the journal
    /// would write it.
    @Test
    func `a parsed entry is weighed as the file wrote it`() throws {
        let (manager, url) = try Self.manager(over: Self.fourPlaceJournal)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try JournalParser().parse("""
        2026-01-03 Card payment abroad
            Expenses:Travel    1.00 EUR @ $1.0851
            Liabilities:Card   $-1.09
        """)
        let entry = try #require(parsed.transactions.first)
        #expect(entry.sourceText != nil)
        #expect(throws: Never.self) { try manager.add(.transaction(entry)) }
    }
}

@Suite("balancing cost inference") struct BalancingCostInferenceTests {
    private static func balance(of text: String) throws -> TransactionBalance {
        let journal = try JournalParser().parse(text)
        return try #require(journal.transactions.first).balance
    }

    /// The commonest multi-currency entry there is: two commodities, no price
    /// written, and hledger reading the second leg as what the first one cost.
    /// It used to make the whole journal fail to open.
    @Test
    func `two commodities of opposite sign balance by conversion`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Exchange
            assets:eur     100 EUR
            assets:usd    -110 USD
        """)
        let conversion = try #require(balance.real.conversion)
        #expect(balance.isBalanced)
        #expect(balance.real.residual == [Amount(quantity: 100, commodity: "EUR"),
                                          Amount(quantity: -110, commodity: "USD")])
        #expect(conversion.from == Amount(quantity: 100, commodity: "EUR"))
        #expect(conversion.to == Amount(quantity: -110, commodity: "USD"))
        #expect(conversion.postingIndices == [0])
        #expect(conversion.price == .total(Amount(quantity: 110, commodity: "USD")))
    }

    /// The cost lands on the commodity of the group's first posting, so the
    /// same exchange written the other way round prices the dollars.
    @Test
    func `the first posting's commodity is the one priced`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Exchange
            assets:usd    -110 USD
            assets:eur     100 EUR
        """)
        let conversion = try #require(balance.real.conversion)
        #expect(conversion.from == Amount(quantity: -110, commodity: "USD"))
        #expect(conversion.price == .total(Amount(quantity: 100, commodity: "EUR")))
    }

    /// Several postings sharing the priced commodity are all priced, at a
    /// rate rather than at a total, and the rate is read off the net, so a
    /// posting whose own sign runs against that net is priced too.
    @Test
    func `several postings in the priced commodity share a per-unit rate`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Exchange
            assets:eur      100 EUR
            assets:eur2     -30 EUR
            assets:usd      -77 USD
        """)
        let conversion = try #require(balance.real.conversion)
        let rate = try #require(Decimal(string: "1.1"))
        #expect(conversion.postingIndices == [0, 1])
        #expect(conversion.price == .perUnit(Amount(quantity: rate, commodity: "USD")))
    }

    /// The rate is kept as exactly as a `Decimal` holds it, rather than
    /// rounded to the four places a report would print: hledger keeps ten
    /// thirds here and prints 3.3333, and a rate rounded in the model would
    /// leave the three postings not adding up.
    @Test
    func `an awkward rate is kept to full precision`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Exchange
            assets:eur      1.00 EUR
            assets:eur2     2.00 EUR
            assets:usd    -10.00 USD
        """)
        let conversion = try #require(balance.real.conversion)
        guard case let .perUnit(rate) = conversion.price else {
            Issue.record("expected a per-unit rate, got \(conversion.price)")
            return
        }
        let printed = try #require(Decimal(string: "3.3333"))
        #expect(rate.quantity != printed)
        #expect(abs(rate.quantity * 3 - 10) < Decimal(sign: .plus, exponent: -30, significand: 1))
    }

    /// A commodity the entry already nets to zero is out of the count before
    /// the two sides are looked for, which is what lets an entry carrying
    /// equity conversion postings balance without anything knowing what an
    /// equity account is.
    @Test
    func `a commodity that nets to zero is not one of the two sides`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Two movements, one settled
            assets:eur     100 EUR
            equity:x      -100 EUR
            assets:gbp      10 GBP
            assets:chf     -12 CHF
        """)
        let conversion = try #require(balance.real.conversion)
        #expect(conversion.postingIndices == [2])
        #expect(conversion.price == .total(Amount(quantity: 12, commodity: "CHF")))
    }

    /// Three commodities, or two of the same sign, is not an exchange: the
    /// entry is simply wrong, and hledger says so too.
    @Test(arguments: ["""
    2026-01-01 Three commodities
        assets:eur     100 EUR
        assets:usd    -110 USD
        assets:gbp      10 GBP
    """, """
    2026-01-01 Both positive
        assets:eur     100 EUR
        assets:usd     110 USD
    """])
    func `only two sides of opposite sign are an exchange`(text: String) throws {
        #expect(throws: LedgerError.self) { try JournalParser().parse(text) }
    }

    /// One written price switches the reading off for the whole group, even
    /// for a pair in other commodities that has nothing to do with it. This
    /// is hledger's sharpest edge here: half-priced never works.
    @Test
    func `a price anywhere in the group switches inference off`() throws {
        #expect(throws: LedgerError.self) {
            try JournalParser().parse("""
            2026-01-01 Priced and unpriced
                assets:eur      50 EUR @ 1.10 USD
                assets:usd     -55 USD
                assets:gbp      10 GBP
                assets:chf     -12 CHF
            """)
        }
    }

    /// The bracketed postings are their own group, so they get their own
    /// conversion, and neither group's prices reach the other.
    @Test
    func `bracketed postings are converted on their own`() throws {
        let balance = try Self.balance(of: """
        2026-01-01 Groceries, and move the food envelope
            expenses:food     100 EUR @@ 110 USD
            assets:checking  -110 USD
            [budget:food]      25 USD
            [budget:avail]    -20 EUR
        """)
        #expect(balance.real.conversion == nil)
        #expect(balance.real.isBalanced)
        let conversion = try #require(balance.balancedVirtual.conversion)
        #expect(conversion.postingIndices == [2])
        #expect(conversion.price == .total(Amount(quantity: 20, commodity: "EUR")))
    }

    /// An elided posting absorbs the remainder instead of triggering a
    /// conversion, which is hledger's reading and what the parser has always
    /// done: this pins the order of the two.
    @Test
    func `an elided posting absorbs the remainder rather than converting it`() throws {
        let transaction = try #require(try JournalParser().parse("""
        2026-01-01 Opening balances
            assets:eur     100 EUR
            assets:usd    -110 USD
            equity:opening
        """).transactions.first)
        #expect(transaction.postings.count == 4)
        #expect(transaction.balance.real.conversion == nil)
        #expect(transaction.balance.isBalanced)
    }

    /// An inferred cost is a reading of the postings, never a change to them:
    /// the file says what the user wrote, and plain `hledger print` writes no
    /// inferred cost either.
    @Test
    func `an inferred cost is never written into the file`() throws {
        let text = """
        2026-01-01 Exchange
            assets:eur     100 EUR
            assets:usd    -110 USD
        """
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.allSatisfy { $0.price == nil } == true)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// The whole point of the API: an entry half typed can be asked what it
    /// is off by without building a transaction and catching.
    @Test
    func `a half-typed entry reports what is missing without throwing`() {
        let postings = [
            Posting(accountName: "Expenses:Food", amount: usd(40)),
            Posting(accountName: "Assets:Cash", amount: usd(-25)),
        ]
        let balance = Transaction.balance(of: postings)
        #expect(!balance.isBalanced)
        #expect(balance.real.residual == [usd(15)])
        #expect(balance.real.conversion == nil)
    }

    /// The journal-aware form answers in the file's own styles and lists the
    /// commodities a picker would offer.
    @Test
    func `a ledger weighs postings in its own styles and lists its commodities`() throws {
        let ledger = try Ledger(journal: JournalParser().parse("""
        2026-01-01 Exchange
            assets:eur     100 EUR
            assets:usd    -110 USD @@ 100 EUR
        """))
        #expect(ledger.commodities == ["EUR", "USD"])
        #expect(ledger.balance(of: [
            Posting(accountName: "Assets:Cash", amount: Amount(quantity: 1, commodity: "EUR")),
            Posting(accountName: "Expenses:Food", amount: Amount(quantity: -1, commodity: "EUR")),
        ]).isBalanced)
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
