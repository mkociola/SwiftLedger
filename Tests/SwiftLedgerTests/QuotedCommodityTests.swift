import Foundation
@testable import SwiftLedger
import Testing

/// A commodity symbol that holds a space, a digit or punctuation is written
/// in double quotes, as hledger writes it, and the quotes are no part of the
/// name: `10 "Mutual Fund"` is ten units of `Mutual Fund`. Read with the
/// quotes kept, the fund was a commodity nobody could query by name, and an
/// entry rebuilt with the bare name split the account in two. Issue #38.
@Suite("commodity symbols in quotes") struct QuotedCommodityTests {
    static func parse(_ amount: String) throws -> Journal {
        try JournalParser().parse("2024-01-01 Fund\n    Assets:Fund    \(amount)\n    Assets:Checking\n")
    }

    static func first(_ amount: String) throws -> Amount {
        try #require(parse(amount).transactions.first?.postings.first?.amount)
    }

    static func entry(_ amount: Amount) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2024, month: 1, day: 1),
            description: "Fund",
            postings: [
                Posting(accountName: "Assets:Fund", amount: amount),
                Posting(accountName: "Assets:Checking", amount: amount.negated),
            ],
        )
    }

    @Test
    func `the quotes are no part of a symbol behind the number`() throws {
        #expect(try Self.first("10 \"Mutual Fund\"") == Amount(quantity: 10, commodity: "Mutual Fund"))
    }

    /// In front of the number, the quoted symbol ends at its closing quote
    /// rather than at the first digit, and whether a space follows it is the
    /// format's to remember, as it is for a bare symbol.
    @Test(arguments: [("\"Mutual Fund\" 10", true), ("\"Mutual Fund\"10", false)])
    func `a quoted symbol in front keeps its side and its space`(amount: String, spaced: Bool) throws {
        let journal = try Self.parse(amount)
        #expect(journal.transactions.first?.postings.first?.amount
            == Amount(quantity: 10, commodity: "Mutual Fund", commodityIsPrefix: true))
        #expect(journal.commodityFormats["Mutual Fund"]?.commodityIsPrefix == true)
        #expect(journal.commodityFormats["Mutual Fund"]?.separatesPrefixCommodity == spaced)
    }

    @Test(arguments: ["-\"Mutual Fund\" 10", "\"Mutual Fund\" -10"])
    func `a sign on either side of a quoted symbol is read`(amount: String) throws {
        #expect(try Self.first(amount) == Amount(quantity: -10, commodity: "Mutual Fund", commodityIsPrefix: true))
    }

    /// Quotes around a symbol that needs none name the bare symbol, so the
    /// two postings below are in one commodity and the entry balances.
    @Test
    func `a quoted simple symbol is the bare symbol`() throws {
        let text = "2024-01-01 Same\n    Expenses:A    10 \"USD\"\n    Assets:B    -10 USD\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.map(\.amount.commodity) == ["USD", "USD"])
    }

    /// Nothing between the quotes names no symbol at all, on either side, so
    /// the number is bare and reads as a bare number does, as it does in
    /// hledger.
    @Test(arguments: ["10 \"\"", "\"\"10", "\"\" 10"])
    func `empty quotes leave the number bare`(amount: String) throws {
        #expect(try Self.first(amount) == Amount(quantity: 10, commodity: ""))
    }

    /// `@` and `=` inside the quotes are part of the symbol, as they are in
    /// hledger, and the price and the assertion open at the first one outside.
    @Test
    func `a price and an assertion are read past a quoted symbol holding their operators`() throws {
        let text = "2024-01-01 Fund\n    Assets:Fund    10 \"A@B\" @ $5.00 = 10 \"A=B\"\n"
            + "    Assets:Checking    -$50.00\n"
        let posting = try #require(JournalParser().parse(text).transactions.first?.postings.first)
        #expect(posting.amount == Amount(quantity: 10, commodity: "A@B"))
        #expect(posting.price == .perUnit(Amount(quantity: 5, commodity: "$", commodityIsPrefix: true)))
        #expect(posting.balanceAssertion == Amount(quantity: 10, commodity: "A=B"))
    }

    /// What hledger refuses is refused here: a quote with no partner, on
    /// either side of the number, and text after the closing quote.
    @Test(arguments: ["10 \"Mutual Fund", "10 \"A\"B", "\"Mutual Fund 10"])
    func `a broken quoted symbol is no amount`(amount: String) throws {
        let error = try #require(throws: LedgerError.self) { try Self.parse(amount) }
        #expect(error.withoutLocation == .invalidAmount(amount))
    }

    /// A `;` opens the comment before the quotes are read, in hledger as here,
    /// so what is left of the amount is a quote with no partner.
    @Test
    func `a semicolon inside the quotes opens the comment`() throws {
        let error = try #require(throws: LedgerError.self) { try Self.parse("10 \"A;B\"") }
        #expect(error.withoutLocation == .invalidAmount("10 \"A"))
    }

    /// A rebuilt amount is written with the quotes when the symbol needs
    /// them, which is hledger's list (a digit, whitespace, or one of
    /// `-+.@*;"{}=`) and the comma, which opens a number here, and bare
    /// otherwise, as hledger's `print` writes it.
    @Test(arguments: [
        ("Mutual Fund", "\"Mutual Fund\""), ("AAPL2", "\"AAPL2\""), ("E,R", "\"E,R\""), ("E*R", "\"E*R\""),
        ("E{R", "\"E{R\""), ("E\tR", "\"E\tR\""), ("USD", "USD"), ("A(B)", "A(B)"), ("m²", "m²"),
    ])
    func `a rebuilt amount quotes a symbol that needs it`(symbol: String, written: String) throws {
        let entry = try Transaction(
            date: JournalDate(year: 2024, month: 1, day: 1),
            description: "Fund",
            postings: [
                Posting(accountName: "Assets:Fund", amount: Amount(quantity: 10, commodity: symbol)),
                Posting(
                    accountName: "Assets:Checking",
                    amount: Amount(quantity: -10, commodity: symbol, commodityIsPrefix: true),
                ),
            ],
        )
        let lines = JournalSerializer().serialize(Journal(items: [.transaction(entry)])).components(separatedBy: "\n")
        #expect(lines[1].hasSuffix("  10 \(written)"))
        #expect(lines[2].hasSuffix("  -\(written)10"))
    }

    /// Every symbol the serializer writes reads back as itself, on either
    /// side of the number, so a symbol with a digit or a space in it is now
    /// one a caller may build an amount in.
    @Test(arguments: ["Mutual Fund", "AAPL2", "E,R", "E@R", "E=R", " EUR", "A  B", "USD"], [false, true])
    func `a written symbol reads back as itself`(symbol: String, isPrefix: Bool) throws {
        let amount = Amount(quantity: 10, commodity: symbol, commodityIsPrefix: isPrefix)
        let written = try JournalSerializer().serialize(Journal(items: [.transaction(Self.entry(amount))]))
        #expect(try JournalParser().parse(written).transactions.first?.postings.first?.amount == amount)
    }

    /// Two characters no quoting can write: the quote itself, which would end
    /// the symbol early, and the `;`, which opens the comment before the
    /// quotes are read. `Transaction.init` refuses them, naming the field.
    @Test(arguments: ["E\"R", "E;R", "\"EUR\""], [false, true])
    func `a symbol no quoting can write is refused`(symbol: String, isPrefix: Bool) throws {
        let amount = Amount(quantity: 10, commodity: symbol, commodityIsPrefix: isPrefix)
        #expect(try CommodityGrammarTests.refusedField { try Self.entry(amount) } == "postings[0].amount.commodity")
    }

    /// A `commodity` or `D` directive names its symbol the way a posting
    /// does, so a quoted one declares the style of the bare name.
    @Test(arguments: ["commodity", "D"])
    func `a directive declares a quoted symbol's style`(keyword: String) throws {
        let text = "\(keyword) \"Mutual Fund\" 1,000.00\n\n2024-01-01 Fund\n"
            + "    Assets:Fund    10 \"Mutual Fund\"\n    Assets:Checking\n"
        let format = try #require(JournalParser().parse(text).commodityFormats["Mutual Fund"])
        #expect(format.fractionDigits == 2)
        #expect(format.groupsThousands == true)
    }
}
