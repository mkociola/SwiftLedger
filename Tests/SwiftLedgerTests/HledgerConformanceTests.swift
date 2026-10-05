import Foundation
@testable import SwiftLedger
import Testing

/// hledger is the reference SwiftLedger reads a journal against.
///
/// Every `NAME.journal` under `Conformance/` was run through hledger by
/// `Scripts/hledger-fixtures.sh`, and what hledger made of it sits beside it:
/// `NAME.print.json` holds every transaction hledger read, with elided
/// amounts filled in and costs inferred, `NAME.balance.json` holds its flat
/// balance report, and `NAME.error.txt` means hledger refused the file. The
/// tests never run hledger; they read the fixtures, read the same journal
/// with `JournalParser`, and compare values, never text.
///
/// A journal SwiftLedger is known to read differently is listed in
/// `knownDivergences`. Its test then passes only while the divergence is
/// still there, so fixing one means taking its name off the list, and the
/// list is the current distance to hledger, in the repository, kept honest
/// by the suite.
@Suite("hledger conformance") struct HledgerConformanceTests {
    /// Journals SwiftLedger does not yet read the way hledger does.
    static let knownDivergences: Set<String> = [
        "alias",
        "amount-forms",
        "apply-account",
        "balance-assertion-fails",
        "cost-inference",
        "date-formats",
        "decimal-mark-directive",
        "default-commodity",
        "description-comment",
        "include",
        "posting-date-tag",
        "secondary-date-without-year",
        "year-directive",
    ]

    /// The corpus, read from the repository rather than bundled, so that
    /// adding a journal and running the script is enough to test it. A file
    /// starting with `_` is a part another journal includes, not a case.
    static var journals: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".journal") && !$0.hasPrefix("_") }
            .map { String($0.dropLast(".journal".count)) }
            .sorted()
    }

    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SwiftLedgerTests
            .appending(path: "Conformance")
    }

    @Test(arguments: journals)
    func `reads the journal as hledger does`(name: String) throws {
        try withKnownIssue("SwiftLedger does not yet read \(name).journal as hledger does") {
            try Self.compare(name)
        } when: {
            Self.knownDivergences.contains(name)
        }
    }

    @Test
    func `the corpus is not empty`() {
        #expect(!Self.journals.isEmpty)
    }

    // MARK: - Comparison

    private static func compare(_ name: String) throws {
        let text = try String(contentsOf: fixture("\(name).journal"), encoding: .utf8)

        if let message = try? String(contentsOf: fixture("\(name).error.txt"), encoding: .utf8) {
            // hledger refused the file, so SwiftLedger has to refuse it too.
            // What it refuses it for is not compared: the messages are
            // hledger's, and only the verdict is the contract.
            if let journal = try? JournalParser().parse(text) {
                Issue.record(
                    """
                    hledger refuses \(name).journal and SwiftLedger read \(journal.transactions.count) \
                    transaction(s) from it.
                    --- hledger
                    \(message)
                    """,
                )
            }
            return
        }

        let journal = try JournalParser().parse(text)
        let decoder = JSONDecoder()
        let expectedTransactions = try decoder.decode(
            [HledgerTransaction].self, from: Data(contentsOf: fixture("\(name).print.json")),
        )
        let expectedBalances = try decoder.decode(
            [HledgerBalanceRow].self, from: Data(contentsOf: fixture("\(name).balance.json")),
        )

        expectSame(
            Self.render(journal.transactions),
            Self.render(expectedTransactions),
            "transactions of \(name).journal",
        )
        expectSame(
            Self.renderBalances(Ledger(journal: journal)),
            Self.renderBalances(expectedBalances),
            "balances of \(name).journal",
        )
    }

    private static func fixture(_ file: String) -> URL {
        directory.appending(path: file)
    }

    /// Records one issue showing both readings in full, so a failure reads as
    /// a diff rather than as two multi-line strings squeezed into an
    /// expression.
    private static func expectSame(_ actual: [String], _ expected: [String], _ what: String) {
        guard actual != expected else { return }
        Issue.record(
            """
            \(what) differ from hledger's reading.
            --- hledger
            \(expected.joined(separator: "\n"))
            --- SwiftLedger
            \(actual.joined(separator: "\n"))
            """,
        )
    }

    // MARK: - Rendering SwiftLedger's reading

    /// One line per transaction and one per posting amount, in the form both
    /// readings are rendered to. hledger prints transactions in date order
    /// and keeps document order within a day, so SwiftLedger's are sorted the
    /// same way before rendering.
    private static func render(_ transactions: [Transaction]) -> [String] {
        let sorted = transactions.enumerated().sorted { lhs, rhs in
            lhs.element.date != rhs.element.date
                ? lhs.element.date < rhs.element.date
                : lhs.offset < rhs.offset
        }
        return sorted.flatMap { render($0.element) }
    }

    private static func render(_ transaction: Transaction) -> [String] {
        var header = transaction.date.description
        if let auxDate = transaction.auxDate { header += "=\(auxDate)" }
        if let mark = marker(transaction.status) { header += " \(mark)" }
        if let code = transaction.code, !code.isEmpty { header += " (\(code))" }
        header += " \(transaction.description)"
        return [header] + transaction.postings.map(render)
    }

    private static func render(_ posting: Posting) -> String {
        var line = "    "
        if let mark = marker(posting.status ?? .unmarked) { line += "\(mark) " }
        line += posting.delimitedAccountName
        line += "  " + render(posting.amount)
        // A total cost is rendered unsigned on both sides: hledger stores it
        // with the sign of the quantity and prints it without, and which sign
        // a store carries is representation, not reading.
        switch posting.price {
        case let .perUnit(price): line += " @ " + render(price)
        case let .total(price): line += " @@ " + render(abs(price.quantity), price.commodity)
        case nil: break
        }
        if let assertion = posting.balanceAssertion {
            line += " = " + render(assertion)
        }
        return line
    }

    private static func render(_ amount: Amount) -> String {
        render(amount.quantity, amount.commodity)
    }

    private static func render(_ quantity: Decimal, _ commodity: String) -> String {
        "\(quantity) \(commodity)"
    }

    private static func marker(_ status: ClearingStatus) -> String? {
        switch status {
        case .unmarked: nil
        case .pending: "!"
        case .cleared: "*"
        }
    }

    /// Every account with a non-zero balance, as `hledger balance --flat -N`
    /// lists them: postings' own accounts only, zero rows dropped.
    private static func renderBalances(_ ledger: Ledger) -> [String] {
        ledger.accounts.flatMap { account in
            ledger.balance(for: account.name)
                .filter { !$0.isZero }
                .map { "\(account.name)  \(render($0))" }
        }.sorted()
    }

    // MARK: - Rendering hledger's reading

    private static func render(_ transactions: [HledgerTransaction]) -> [String] {
        transactions.flatMap { transaction in
            var header = transaction.date
            if let date2 = transaction.date2 { header += "=\(date2)" }
            if let mark = marker(transaction.status) { header += " \(mark)" }
            if !transaction.code.isEmpty { header += " (\(transaction.code))" }
            header += " \(transaction.description)"
            return [header] + transaction.postings.flatMap(render)
        }
    }

    private static func render(_ posting: HledgerPosting) -> [String] {
        posting.amounts.map { amount in
            var line = "    "
            if let mark = marker(posting.status) { line += "\(mark) " }
            line += posting.delimitedAccount
            line += "  " + render(amount.quantity, amount.commodity)
            if let cost = amount.cost {
                line += cost.total
                    ? " @@ " + render(abs(cost.quantity), cost.commodity)
                    : " @ " + render(cost.quantity, cost.commodity)
            }
            if let assertion = posting.assertion {
                line += " = " + render(assertion.quantity, assertion.commodity)
            }
            if let date = posting.date {
                line += "  ; date:\(date)"
            }
            return line
        }
    }

    private static func renderBalances(_ rows: [HledgerBalanceRow]) -> [String] {
        rows.flatMap { row in
            row.amounts
                .filter { $0.quantity != .zero }
                .map { "\(row.account)  \(render($0.quantity, $0.commodity))" }
        }.sorted()
    }

    private static func marker(_ status: String) -> String? {
        switch status {
        case "Pending": "!"
        case "Cleared": "*"
        default: nil
        }
    }
}

// MARK: - The fixture format

/// The projection of hledger's `print -O json` that the script writes.
private struct HledgerTransaction: Decodable {
    var date: String
    var date2: String?
    var status: String
    var code: String
    var description: String
    var postings: [HledgerPosting]
}

private struct HledgerPosting: Decodable {
    var account: String
    var kind: String
    var status: String
    var date: String?
    var amounts: [HledgerAmount]
    var assertion: HledgerAssertion?

    var delimitedAccount: String {
        switch kind {
        case "VirtualPosting": "(\(account))"
        case "BalancedVirtualPosting": "[\(account)]"
        default: account
        }
    }
}

private struct HledgerAmount: Decodable {
    var commodity: String
    var mantissa: Int
    var places: Int
    var cost: HledgerCost?

    var quantity: Decimal {
        decimal(mantissa, places)
    }
}

private struct HledgerCost: Decodable {
    var total: Bool
    var commodity: String
    var mantissa: Int
    var places: Int

    var quantity: Decimal {
        decimal(mantissa, places)
    }
}

private struct HledgerAssertion: Decodable {
    var commodity: String
    var mantissa: Int
    var places: Int
    var total: Bool
    var inclusive: Bool

    var quantity: Decimal {
        decimal(mantissa, places)
    }
}

/// One row of `balance --flat -N -O json`.
private struct HledgerBalanceRow: Decodable {
    var account: String
    var amounts: [HledgerAmount]
}

/// hledger's exact decimal: an integer mantissa and the number of places
/// after the point, which is what keeps the comparison free of rounding.
private func decimal(_ mantissa: Int, _ places: Int) -> Decimal {
    Decimal(sign: mantissa < 0 ? .minus : .plus, exponent: -places, significand: Decimal(abs(mantissa)))
}
