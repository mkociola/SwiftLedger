import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's include line. Each topic of the example keeps
/// its tests in a file of its own, so that changes made side by side add to
/// different files rather than all growing one past the length SwiftLint
/// allows.
extension ExampleJournalTests {
    static var exampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SwiftLedgerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appending(path: "Examples/sample.ledger")
    }

    /// Opened from its file, the example reads the bus pass out of
    /// `sample-include.ledger` at the include line and books it plainly,
    /// since no alias or apply account line is open there, and both files
    /// are written back byte for byte. Parsed from text, the line is kept as
    /// it came and the entry is not read.
    @Test
    func `the example's include line reads the entry from the other file`() throws {
        let journal = try JournalParser().parse(fileAt: Self.exampleURL)
        let pass = try #require(journal.transactions.first { $0.description == "Bus pass, kept in a file of its own" })
        #expect(pass.postings.map(\.accountName) == ["Expenses:Transport", "Assets:Checking"])
        #expect(pass.postings.first?.amount == Amount(quantity: 45, commodity: "$", commodityIsPrefix: true))
        let included = journal.items.compactMap { if case let .include(files) = $0 { files } else { nil } }
        #expect(included.map(\.line) == ["include sample-include.ledger"])
        let part = try #require(included.first?.journals.first?.file)
        #expect(part.lastPathComponent == "sample-include.ledger")
        let texts = try [Self.exampleText, String(contentsOf: part, encoding: .utf8)]
        #expect(JournalSerializer().serializedFiles(journal).map(\.text) == texts)
        #expect(Ledger(journal: journal).checkBalanceAssertions().isEmpty)

        let text = try JournalParser().parse(Self.exampleText)
        #expect(text.items.contains(.directive("include sample-include.ledger")))
        #expect(!text.transactions.contains { $0.description == pass.description })
    }
}
