import Foundation
@testable import SwiftLedger
import Testing

// swiftlint:disable file_length

// MARK: - Helpers

/// A `Decimal` from its text. A float literal would go through `Double`.
private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
}

private func amount(_ quantity: String, _ commodity: String) -> Amount {
    Amount(quantity: dec(quantity), commodity: commodity)
}

private func posting(
    _ quantity: String,
    _ commodity: String,
    price: PostingPrice? = nil,
    kind: Posting.Kind = .real,
) -> Posting {
    Posting(accountName: "Assets:Any", kind: kind, amount: amount(quantity, commodity), price: price)
}

// MARK: - The verdict on postings built in code

@Suite("balance verdict") struct BalanceVerdictTests {
    @Test
    func `one commodity that sums to zero is balanced`() {
        let verdict = Transaction.balance(of: [posting("50", "USD"), posting("-50", "USD")])
        #expect(verdict.real == .balanced)
        #expect(verdict.bracketed == .balanced)
    }

    @Test
    func `two commodities of opposite sign are an exchange`() {
        let verdict = Transaction.balance(of: [posting("100", "EUR"), posting("-110", "USD")])
        #expect(verdict.real == .exchange(from: amount("100", "EUR"), to: amount("-110", "USD")))
    }

    @Test
    func `the from side is the first of the two commodities left over`() {
        let verdict = Transaction.balance(of: [
            posting("5", "GBP"), posting("-5", "GBP"),
            posting("-110", "USD"), posting("100", "EUR"),
        ])
        #expect(verdict.real == .exchange(from: amount("-110", "USD"), to: amount("100", "EUR")))
    }

    @Test
    func `two commodities of the same sign are unbalanced`() {
        let verdict = Transaction.balance(of: [posting("100", "EUR"), posting("110", "USD")])
        #expect(verdict.real == .unbalanced([amount("100", "EUR"), amount("110", "USD")]))
    }

    @Test
    func `three commodities are unbalanced`() {
        let verdict = Transaction.balance(of: [
            posting("100", "EUR"), posting("-110", "USD"), posting("5", "GBP"),
        ])
        #expect(verdict.real == .unbalanced([
            amount("100", "EUR"), amount("-110", "USD"), amount("5", "GBP"),
        ]))
    }

    @Test
    func `a fee in the second commodity is netted into the exchange`() {
        let verdict = Transaction.balance(of: [
            posting("10", "AAPL"), posting("5", "USD"), posting("-1505", "USD"),
        ])
        #expect(verdict.real == .exchange(from: amount("10", "AAPL"), to: amount("-1500", "USD")))
    }

    @Test
    func `a priced posting left standing rules an exchange out`() {
        let verdict = Transaction.balance(of: [
            posting("10", "AAPL", price: .perUnit(amount("150", "USD"))),
            posting("-1500", "USD"),
            posting("100", "EUR"),
            posting("-110", "USD"),
        ])
        #expect(verdict.real == .unbalanced([amount("-110", "USD"), amount("100", "EUR")]))
    }

    @Test(arguments: [
        PostingPrice.perUnit(Amount(quantity: 150, commodity: "USD")),
        PostingPrice.total(Amount(quantity: 1500, commodity: "USD")),
    ])
    func `priced postings that cancel leave the exchange standing`(price: PostingPrice) {
        let verdict = Transaction.balance(of: [
            posting("10", "AAPL", price: price),
            posting("-10", "AAPL", price: price),
            posting("100", "EUR"),
            posting("-110", "USD"),
        ])
        #expect(verdict.real == .exchange(from: amount("100", "EUR"), to: amount("-110", "USD")))
    }

    @Test
    func `total-priced postings that cancel in quantity but not in cost rule an exchange out`() {
        let total = PostingPrice.total(amount("1500", "USD"))
        let verdict = Transaction.balance(of: [
            posting("4", "AAPL", price: total),
            posting("6", "AAPL", price: total),
            posting("-10", "AAPL", price: total),
            posting("100", "EUR"),
            posting("-110", "USD"),
        ])
        #expect(verdict.real == .unbalanced([amount("1390", "USD"), amount("100", "EUR")]))
    }

    @Test
    func `a quantity that is not a number never balances`() throws {
        let unknown = Posting(accountName: "Assets:Any", amount: Amount(quantity: .nan, commodity: "USD"))
        let date = try JournalDate(year: 2026, month: 1, day: 1)
        #expect(throws: LedgerError.self) {
            try Transaction(date: date, description: "Not a number", postings: [unknown, posting("-1", "USD")])
        }
    }

    @Test
    func `a residual under half of the last place written is zero`() {
        let verdict = Transaction.balance(of: [
            posting("33.33", "EUR", price: .perUnit(amount("1.0837", "USD"))),
            posting("-36.12", "USD"),
        ])
        #expect(verdict.real == .balanced)
    }

    @Test
    func `exactly half of the last place balances and more does not`() {
        let half = Transaction.balance(of: [
            posting("1", "EUR", price: .perUnit(amount("1.5", "USD"))), posting("-1", "USD"),
        ])
        let over = Transaction.balance(of: [
            posting("1", "EUR", price: .perUnit(amount("1.6", "USD"))), posting("-1", "USD"),
        ])
        #expect(half.real == .balanced)
        #expect(over.real == .unbalanced([amount("0.6", "USD")]))
    }

    @Test
    func `formats measure an amount at the digits it will be written with`() {
        let postings = [
            posting("1", "EUR", price: .perUnit(amount("1.4", "USD"))), posting("-1", "USD"),
        ]
        let cents = ["USD": CommodityFormat(fractionDigits: 2)]
        #expect(Transaction.balance(of: postings).real == .balanced)
        #expect(Transaction.balance(of: postings, formats: [:]).real == .balanced)
        #expect(Transaction.balance(of: postings, formats: cents).real == .unbalanced([amount("0.4", "USD")]))
    }

    @Test
    func `a virtual posting's digits tighten the real group`() {
        let verdict = Transaction.balance(of: [
            posting("1", "EUR", price: .perUnit(amount("1.4", "USD"))),
            posting("-1", "USD"),
            posting("5.25", "USD", kind: .virtual),
        ])
        #expect(verdict.real == .unbalanced([amount("0.4", "USD")]))
    }

    @Test
    func `a commodity named only by prices is measured at the prices' digits`() {
        let refused = Transaction.balance(of: [
            posting("1", "EUR", price: .perUnit(amount("1.0851", "USD"))),
            posting("-0.5", "GBP", price: .perUnit(amount("2.17", "USD"))),
        ])
        let accepted = Transaction.balance(of: [
            posting("1", "EUR", price: .perUnit(amount("1.09", "USD"))),
            posting("-0.5", "GBP", price: .perUnit(amount("2.17", "USD"))),
        ])
        #expect(refused.real == .unbalanced([amount("0.0001", "USD")]))
        #expect(accepted.real == .balanced)
    }

    @Test
    func `bracketed postings are judged among themselves`() {
        let verdict = Transaction.balance(of: [
            posting("10", "USD"), posting("-10", "USD"),
            posting("5", "EUR", kind: .balancedVirtual), posting("-6", "USD", kind: .balancedVirtual),
        ])
        #expect(verdict.real == .balanced)
        #expect(verdict.bracketed == .exchange(from: amount("5", "EUR"), to: amount("-6", "USD")))
    }
}

// MARK: - The digits the serializer writes

@Suite("written fraction digits") struct WrittenFractionDigitsTests {
    @Test
    func `a number is padded up to the format's floor and never cut`() {
        let cents = CommodityFormat(fractionDigits: 2)
        #expect(cents.writtenFractionDigits(of: dec("36.1")) == 2)
        #expect(cents.writtenFractionDigits(of: dec("36.123")) == 3)
        #expect(cents.writtenFractionDigits(of: dec("-36")) == 2)
    }

    @Test
    func `with no floor it is the digits the number needs`() {
        #expect(CommodityFormat().writtenFractionDigits(of: dec("1.00")) == 0)
        #expect(CommodityFormat().writtenFractionDigits(of: dec("36.104")) == 3)
    }

    @Test
    func `a group mark is not read as the decimal mark`() {
        let european = CommodityFormat(fractionDigits: 2, groupsThousands: true, decimalMark: ",")
        let whole = CommodityFormat(groupsThousands: true, decimalMark: ",")
        #expect(european.writtenFractionDigits(of: dec("1234.5")) == 2)
        #expect(whole.writtenFractionDigits(of: dec("12345")) == 0)
    }
}

// MARK: - The same rules in a file

/// One entry measured against hledger 1.52.4 on 2026-10-05.
struct Probe: CustomTestStringConvertible {
    /// The posting lines, without indentation.
    let body: String
    let loads: Bool

    var testDescription: String {
        body.replacingOccurrences(of: "\n", with: " / ")
    }

    var journal: String {
        let lines = body.split(separator: "\n").map { "    \($0)" }
        return (["2026-01-01 probe"] + lines).joined(separator: "\n") + "\n"
    }
}

@Suite("exchange and rounding in a file") struct ExchangeInAFileTests {
    static let probes: [Probe] = [
        Probe(body: "a  100 EUR\nb  -110 USD", loads: true),
        Probe(body: "b  -110 USD\na  100 EUR", loads: true),
        Probe(body: "a  100 EUR\nb  110 USD", loads: false),
        Probe(body: "a  100 EUR\nb  -110 USD\nc  5 GBP", loads: false),
        Probe(body: "a  60 EUR\na2  40 EUR\nb  -110 USD", loads: true),
        Probe(body: "a  2 EUR\na2  1 EUR\nb  -110 USD", loads: true),
        Probe(body: "a  100 EUR\na2  -10 EUR\nb  -99 USD", loads: true),
        Probe(body: "a  10 AAPL\nf  5 USD\nb  -1505 USD", loads: true),
        Probe(body: "a  100 EUR\nb  -110 USD\nc", loads: true),
        Probe(body: "a  10 AAPL @ 150 USD\nb  -1500 USD\nc  100 EUR\nd  -110 USD", loads: false),
        Probe(body: "a  10 AAPL @ 150 USD\na2  -10 AAPL @ 150 USD\nc  100 EUR\nd  -110 USD", loads: true),
        Probe(body: "a  10 AAPL @@ 1500 USD\na2  -10 AAPL @@ 1500 USD\nc  100 EUR\nd  -110 USD", loads: true),
        Probe(body: "a  5 GBP\na2  -5 GBP\nc  100 EUR\nd  -110 USD", loads: true),
        Probe(
            body: "a  4 AAPL @@ 1500 USD\na2  6 AAPL @@ 1500 USD\na3  -10 AAPL @@ 1500 USD\nc  100 EUR\nd  -110 USD",
            loads: false,
        ),
        Probe(body: "z  0 AAPL @@ 100 USD\nc  100 EUR\nd  -110 USD", loads: false),
        Probe(body: "a  5.001 GBP\na2  -5 GBP\nc  100 EUR\nd  -110 USD", loads: false),
        Probe(body: "a  100 EUR\nb  -110 USD\n[v1]  5 EUR\n[v2]  -6 USD", loads: true),
        Probe(body: "a  33.33 EUR @ 1.0837 USD\nb  -36.12 USD", loads: true),
        Probe(body: "a  1 EUR @ 1.005 USD\nb  -1.00 USD", loads: true),
        Probe(body: "a  1 EUR @ 1.006 USD\nb  -1.00 USD", loads: false),
        Probe(body: "a  1 EUR @ 1.4 USD\nb  -1 USD", loads: true),
        Probe(body: "a  1 EUR @ 1.5 USD\nb  -1 USD", loads: true),
        Probe(body: "a  1 EUR @ 1.6 USD\nb  -1 USD", loads: false),
        Probe(body: "a  10.00 USD\nb  -10.004 USD", loads: false),
        Probe(body: "a  10.00 USD\nb  -9.996 USD", loads: false),
        Probe(body: "a  36.100 USD\nb  -36.104 USD", loads: false),
        Probe(body: "a  1 EUR @ 1.4 USD\nb  -1 USD\n(v)  5.00 USD", loads: false),
        Probe(body: "a  1 EUR @ 1.4 USD\nb  -1 USD\n[v]  5.00 USD\n[w]  -5.00 USD", loads: false),
        Probe(body: "a  1 EUR @ 1.0851 USD\nb  -0.5 GBP @ 2.17 USD", loads: false),
        Probe(body: "a  1 EUR @ 1.09 USD\nb  -0.5 GBP @ 2.17 USD", loads: true),
        Probe(body: "a  1 EUR @ 1.089 USD\nb  -0.5 GBP @ 2.17 USD", loads: false),
        Probe(body: "a  1 EUR @@ 1.0851 USD\nb  -1 GBP @@ 1.08 USD", loads: false),
        Probe(body: "a  1 EUR @@ 1.0851 USD\nb  -1 GBP @@ 1.0850 USD", loads: false),
    ]

    @Test(arguments: probes)
    func `an entry loads exactly when hledger loads it`(probe: Probe) {
        let journal = try? JournalParser().parse(probe.journal)
        #expect((journal != nil) == probe.loads)
    }

    @Test
    func `a refused exchange names the first commodity it is off in, and the line`() throws {
        let text = """
        2026-01-01 Same sign
            Assets:Euros    100 EUR
            Assets:Dollars  110 USD
        """
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .unbalancedTransaction(commodity: "EUR", imbalance: 100))
        #expect(error.line == 1)
    }

    @Test
    func `an exchange is written back as it was read, with no cost added`() throws {
        let text = """
        2026-01-01 Change money
            Assets:Euros     100 EUR
            Assets:Dollars  -110 USD

        """
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
        #expect(journal.transactions.first?.postings.allSatisfy { $0.price == nil } == true)
    }

    @Test
    func `an exchange built in code is a valid transaction`() throws {
        let transaction = try Transaction(
            date: JournalDate(year: 2026, month: 1, day: 1),
            description: "Change money",
            postings: [posting("100", "EUR"), posting("-110", "USD")],
        )
        #expect(transaction.postings.count == 2)
    }
}

// MARK: - What a manager will save

@Suite("saving what will load back") struct ReloadableSaveTests {
    /// A journal that writes USD to the cent.
    static let cents = """
    2026-01-01 Opening
        Assets:Checking   100.00 USD
        Equity:Opening   -100.00 USD

    """

    /// A journal that writes USD in whole units.
    static let whole = """
    2026-01-01 Opening
        Assets:Checking   100 USD
        Equity:Opening   -100 USD

    """

    private func manager(holding text: String) throws -> LedgerManager {
        try LedgerManager(store: InMemoryLedgerStore(ledger: Ledger(journal: JournalParser().parse(text))))
    }

    private func entry(_ postings: [Posting]) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2026, month: 1, day: 2), description: "Built in code", postings: postings,
        )
    }

    /// Balances at the digits the numbers need, off by 0.40 once USD is
    /// written to the cent.
    private var roughlyBalanced: [Posting] {
        [posting("1", "EUR", price: .perUnit(amount("1.4", "USD"))), posting("-1", "USD")]
    }

    @Test
    func `add accepts an exchange and the file holds no cost`() throws {
        let manager = try manager(holding: Self.cents)
        try manager.add(.transaction(entry([posting("100", "EUR"), posting("-110", "USD")])))
        let text = JournalSerializer().serialize(manager.currentJournal)
        #expect(!text.contains("@"))
        #expect(try JournalParser().parse(text).transactions.count == 2)
    }

    @Test
    func `add refuses an entry the journal would write unbalanced`() throws {
        let manager = try manager(holding: Self.cents)
        let transaction = try entry(roughlyBalanced)
        #expect(throws: LedgerError.unbalancedTransaction(commodity: "USD", imbalance: dec("0.4"))) {
            try manager.add(.transaction(transaction))
        }
        #expect(manager.transactions().count == 1)
    }

    @Test
    func `add accepts the same entry where the journal writes whole units`() throws {
        let manager = try manager(holding: Self.whole)
        try manager.add(.transaction(entry(roughlyBalanced)))
        let text = JournalSerializer().serialize(manager.currentJournal)
        #expect(try JournalParser().parse(text).transactions.count == 2)
    }

    @Test
    func `a rebuilt entry is accepted in a journal that writes the commodity mostly as a rate`() throws {
        // USD appears mostly as a rate here. Its digits are learned from the
        // one amount posted in it, so a rebuilt cash leg is written -36.12
        // and not -36.1200, where the entry would be off by 0.000279.
        let rates = """
        2026-01-01 Hotel
            Expenses:Travel    33.33 EUR @ 1.0837 USD
            Assets:Dollars    -36.12 USD

        2026-01-02 Dinner
            Expenses:Food      20.00 EUR @ 1.0841 USD
            Assets:Euros      -20.00 EUR @ 1.0841 USD

        2026-01-03 Taxi
            Expenses:Travel    10.00 EUR @ 1.0850 USD
            Assets:Euros      -10.00 EUR @ 1.0850 USD

        """
        let manager = try manager(holding: rates)
        let hotel = try #require(manager.transactions().first)
        let rebuilt = try Transaction(
            id: hotel.id, date: hotel.date, description: "Hotel, two nights", postings: hotel.postings,
        )
        let formats = manager.currentJournal.commodityFormats
        #expect(formats["USD"]?.fractionDigits == 2)
        #expect(formats["USD"]?.maxFractionDigits == 4)
        #expect(try manager.replace(.transaction(hotel), with: .transaction(rebuilt)))
        let text = JournalSerializer().serialize(manager.currentJournal)
        #expect(text.contains("33.33 EUR @ 1.0837 USD\n"))
        #expect(text.contains("-36.12 USD\n"))
        #expect(try JournalParser().parse(text).transactions.count == 3)
    }

    @Test
    func `a commodity nothing is posted in learns its digits from prices`() throws {
        let journal = try JournalParser().parse("""
        2026-01-02 Dinner
            Expenses:Food      20.00 EUR @ 1.0841 USD
            Assets:Euros      -20.00 EUR @ 1.0841 USD

        """)
        #expect(journal.commodityFormats["USD"]?.fractionDigits == 4)
        #expect(journal.commodityFormats["EUR"]?.fractionDigits == 2)
    }

    @Test
    func `replace reports a missing original before it weighs the replacement`() throws {
        let manager = try manager(holding: Self.cents)
        let stale = try entry([posting("5", "USD"), posting("-5", "USD")])
        let replacement = try entry(roughlyBalanced)
        #expect(try manager.replace(.transaction(stale), with: .transaction(replacement)) == false)
        #expect(JournalSerializer().serialize(manager.currentJournal) == Self.cents)
    }

    @Test
    func `a parsed entry removed and added again is accepted`() throws {
        let entry = """
        2026-01-02 Fewer digits than usual
            Expenses:Travel    1 EUR @ 1.4 USD
            Assets:Checking   -1 USD
        """
        let manager = try manager(holding: Self.cents + "\n" + entry + "\n")
        let parsed = try #require(manager.transactions().last)
        #expect(parsed.sourceText != nil)
        try manager.remove(.transaction(parsed))
        try manager.add(.transaction(parsed))
        // Put back as the lines it was read from, not padded to `-1.00 USD`.
        #expect(JournalSerializer().serialize(manager.currentJournal).contains(entry))
        #expect(manager.transactions().count == 2)
    }

    @Test
    func `replace refuses likewise and leaves the journal as it was`() throws {
        let manager = try manager(holding: Self.cents)
        let opening = try #require(manager.transactions().first)
        let replacement = try entry(roughlyBalanced)
        #expect(throws: LedgerError.self) {
            try manager.replace(.transaction(opening), with: .transaction(replacement))
        }
        #expect(JournalSerializer().serialize(manager.currentJournal) == Self.cents)
    }

    @Test
    func `the manager's verdict is the one its save gives`() throws {
        let cents = try manager(holding: Self.cents)
        let whole = try manager(holding: Self.whole)
        #expect(cents.balance(of: roughlyBalanced).real == .unbalanced([amount("0.4", "USD")]))
        #expect(whole.balance(of: roughlyBalanced).real == .balanced)
    }

    @Test(arguments: [
        [("100", "EUR"), ("-110", "USD")],
        [("10", "AAPL"), ("5", "USD"), ("-1505", "USD")],
        [("36.12", "USD"), ("-36.12", "USD")],
        [("0.5", "BTC"), ("-30000", "USD")],
    ])
    func `whatever add accepts parses back`(legs: [(String, String)]) throws {
        let manager = try manager(holding: Self.cents)
        try manager.add(.transaction(entry(legs.map { posting($0.0, $0.1) })))
        let text = JournalSerializer().serialize(manager.currentJournal)
        #expect(try JournalParser().parse(text).transactions.count == 2)
    }
}
