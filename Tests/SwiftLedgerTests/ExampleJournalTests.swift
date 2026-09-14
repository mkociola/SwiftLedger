import Foundation
@testable import SwiftLedger
import Testing

/// `Examples/sample.ledger` is what the README points a reader at as a
/// complete journal, so it has to load with the parser it ships beside, and
/// what it demonstrates has to be true.
@Suite("example journal") struct ExampleJournalTests {
    /// The example file, read from the repository rather than bundled, so
    /// that editing it is enough to test it.
    private static var exampleText: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // SwiftLedgerTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // repository root
                .appending(path: "Examples/sample.ledger")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test
    func `the example parses and is written back byte-for-byte`() throws {
        let text = try Self.exampleText
        let journal = try JournalParser().parse(text)
        #expect(!journal.transactions.isEmpty)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `the example shows entries with fewer than two postings`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let byPayee = Dictionary(
            journal.transactions.map { ($0.description, $0) },
            uniquingKeysWith: { first, _ in first },
        )

        let note = try #require(byPayee["Called the bank about the card fee"])
        #expect(note.postings.isEmpty)

        let brokerage = try #require(byPayee["Opened a brokerage account"])
        #expect(brokerage.postings.map(\.accountName) == ["Assets:Brokerage"])
        #expect(brokerage.postings.map(\.amount.quantity) == [0])

        let petty = try #require(byPayee["Set up the petty cash tin"])
        #expect(petty.postings.map(\.accountName) == ["Assets:PettyCash"])
        #expect(petty.postings.map(\.amount.quantity) == [0])

        let check = try #require(byPayee["Statement check"])
        #expect(check.postings.map(\.accountName) == ["Assets:Savings"])
        #expect(check.postings.map(\.amount.quantity) == [0])
        let asserted = Amount(quantity: 5000, commodity: "$", commodityIsPrefix: true)
        #expect(check.postings.first?.balanceAssertion == asserted)
    }

    /// The library preserves a balance assertion without checking it, so the
    /// example has to be honest on its own: the figure it asserts is the
    /// balance the entries above it produce.
    @Test
    func `the asserted balance in the example is the real one`() throws {
        let ledger = try Ledger(journal: JournalParser().parse(Self.exampleText))
        let savings = ledger.balance(for: "Assets:Savings")
        #expect(savings.map(\.quantity) == [5000])
        #expect(ledger.balance(for: "Assets:Brokerage").allSatisfy { $0.quantity == 0 })
        #expect(ledger.balance(for: "Assets:PettyCash").allSatisfy { $0.quantity == 0 })
    }
}
