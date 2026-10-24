import Foundation
@testable import SwiftLedger
import Testing

/// `Examples/sample.ledger` is what the README points a reader at as a
/// complete journal, so it has to load with the parser it ships beside, and
/// what it demonstrates has to be true.
@Suite("example journal") struct ExampleJournalTests {
    /// The example file, read from the repository rather than bundled, so
    /// that editing it is enough to test it. Internal rather than private so
    /// that the example tests kept in files of their own can read it.
    static var exampleText: String {
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

    /// The example is also a style sample: every entry a reader adds to it,
    /// and every entry SwiftLedger rebuilds in it, is laid out from what the
    /// file already shows. An entry that lines its amounts up somewhere new,
    /// or that writes the file's first negative amount the other way round,
    /// moves that answer for the whole file. That is how the virtual-posting
    /// entry silently flipped the margin from 27 to 31 and the sign from `-$`
    /// to `$-` before it was aligned.
    @Test
    func `the example teaches one margin and one negative-sign style`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        #expect(journal.amountAlignment == .start(column: 27))
        #expect(journal.commodityFormats["$"]?.signPrecedesCommodity == true)
    }

    /// A failed balance assertion does not stop the example loading, so the
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
