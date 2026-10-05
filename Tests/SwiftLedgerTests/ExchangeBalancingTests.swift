import Foundation
@testable import SwiftLedger
import Testing

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
