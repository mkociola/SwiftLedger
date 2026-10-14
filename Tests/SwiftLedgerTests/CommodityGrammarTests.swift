import Foundation
@testable import SwiftLedger
import Testing

/// A commodity is written bare on the posting line, after the number or in
/// front of it, and so is the commodity of a price or a balance assertion. A
/// spelling the amount grammar reads as something else, a digit after the
/// number, a `-` in front of it, an `@` anywhere, used to be accepted, written,
/// and then refused by the next load, or read back as a different commodity.
/// `Transaction.init` refuses it instead. Issue #70.
@Suite("commodity spellings the amount grammar cannot read back") struct CommodityGrammarTests {
    /// Every spelling here is tried on both sides of the number.
    static let spellings = [
        "USD", "$", "€", "EUR2", "2EUR", "E@R", "E=R", "E;R", "-EUR", "+EUR", "E-R", "E+R", "E-", "E+",
        "E.R", "E,R", ".E", ",E", "E.", "E,", "E R", "E\tR", " EUR", "EUR ", "", "E\"R", "\"EUR\"", "\"EUR2\"",
        "E(R)", "(EUR)", "E*R", "*", "!", "E!R", "#E", "E{R",
    ]

    static func rent(_ amount: Amount) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2026, month: 7, day: 1),
            description: "Rent",
            postings: [
                Posting(accountName: "Expenses:Rent", amount: amount),
                Posting(accountName: "Assets:Checking", amount: amount.negated),
            ],
        )
    }

    /// The commodity the serializer's line for `amount` reads back as, or
    /// `nil` when that line does not load. Built by hand rather than through
    /// `init`, which is what is under test.
    static func readBack(_ amount: Amount) -> Amount? {
        let number = amount.commodityIsPrefix ? "\(amount.commodity)100" : "100 \(amount.commodity)"
        let text = "2026-07-01 Rent\n    Expenses:Rent  \(number)\n    Assets:Checking\n"
        return try? JournalParser().parse(text).transactions.first?.postings.first?.amount
    }

    /// The rule `init` applies is the parser's own: a spelling is accepted
    /// exactly when the line written for it loads back as the same commodity
    /// on the same side.
    @Test(arguments: spellings, [false, true])
    func `a commodity is accepted exactly when it reads back as itself`(symbol: String, isPrefix: Bool) throws {
        let amount = Amount(quantity: 100, commodity: symbol, commodityIsPrefix: isPrefix)
        let back = Self.readBack(amount)
        let readsBack = back?.commodity == symbol && back?.commodityIsPrefix == isPrefix
        if readsBack {
            #expect(throws: Never.self) { try Self.rent(amount) }
        } else {
            let error = try #require(throws: LedgerError.self) { try Self.rent(amount) }
            guard case let .syntaxInField(path, _) = error else {
                Issue.record("expected syntaxInField, got \(error)")
                return
            }
            #expect(path == "postings[0].amount.commodity")
        }
    }

    @Test
    func `the digit from the report is refused on either side`() {
        for isPrefix in [false, true] {
            #expect(throws: LedgerError.self) {
                try Self.rent(Amount(quantity: 100, commodity: "EUR2", commodityIsPrefix: isPrefix))
            }
        }
    }

    @Test
    func `a price commodity is checked by the same rule`() throws {
        let error = try #require(throws: LedgerError.self) {
            try Transaction(
                date: JournalDate(year: 2026, month: 7, day: 1),
                description: "Exchange",
                postings: [
                    Posting(
                        accountName: "Assets:Checking",
                        amount: Amount(quantity: 100, commodity: "EUR"),
                        price: .perUnit(Amount(quantity: 1.1, commodity: "USD2")),
                    ),
                    Posting(accountName: "Income:Salary", amount: Amount(quantity: -110, commodity: "USD2")),
                ],
            )
        }
        guard case let .syntaxInField(path, _) = error else {
            Issue.record("expected syntaxInField, got \(error)")
            return
        }
        #expect(path == "postings[0].price.amount.commodity")
    }

    @Test
    func `a balance assertion commodity is checked by the same rule`() throws {
        let dollars = Amount(quantity: 1200, commodity: "$", commodityIsPrefix: true)
        let error = try #require(throws: LedgerError.self) {
            try Transaction(
                date: JournalDate(year: 2026, month: 7, day: 1),
                description: "Rent",
                postings: [
                    Posting(accountName: "Expenses:Rent", amount: dollars),
                    Posting(
                        accountName: "Assets:Checking",
                        amount: dollars.negated,
                        balanceAssertion: Amount(quantity: 0, commodity: "USD=0"),
                    ),
                ],
            )
        }
        guard case let .syntaxInField(path, _) = error else {
            Issue.record("expected syntaxInField, got \(error)")
            return
        }
        #expect(path == "postings[1].balanceAssertion.commodity")
    }

    /// A bare number has no commodity written, and the parser reads it as
    /// `USD`, which passes; only an amount built in code can carry the empty
    /// commodity, which the next load would read back as `USD`.
    @Test
    func `a journal of bare numbers keeps loading`() throws {
        let journal = try JournalParser().parse("2026-07-01 Rent\n    Expenses:Rent  100\n    Assets:Checking\n")
        #expect(journal.transactions.first?.postings.first?.amount.commodity == "USD")
    }

    /// A transaction decoded from JSON goes through `init`, so a commodity
    /// edited into a document by hand is refused by the same check.
    @Test
    func `a decoded transaction refuses a commodity holding a digit`() throws {
        let clean = try Self.rent(Amount(quantity: 100, commodity: "EUR"))
        let json = try #require(String(data: JSONEncoder().encode(clean), encoding: .utf8))
        let broken = json.replacingOccurrences(of: #""commodity":"EUR""#, with: #""commodity":"EUR2""#)
        #expect(broken != json)
        #expect(throws: LedgerError.self) {
            try JSONDecoder().decode(Transaction.self, from: Data(broken.utf8))
        }
    }

    /// The path the report took: an entry built from a form and handed to the
    /// manager. It is refused before anything is written, so the file on disk
    /// is the one that was there and still loads.
    @Test
    func `the journal file is left untouched when the entry is refused`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).ledger")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "2026-07-01 Rent\n    Expenses:Rent  $1200.00\n    Assets:Checking\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let manager = try LedgerManager(store: PlainTextJournalStore(url: url))

        #expect(throws: LedgerError.self) {
            try manager.add(.transaction(Self.rent(Amount(quantity: 100, commodity: "EUR2"))))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(throws: Never.self) { try LedgerManager(store: PlainTextJournalStore(url: url)) }
    }
}
