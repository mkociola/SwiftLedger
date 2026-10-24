import Foundation
@testable import SwiftLedger
import Testing

/// A journal read from a file that includes others is a tree: the `include`
/// line holds the journal of every file it names. Everything that asks a
/// journal for its entries or its declared accounts has to see every file,
/// in the order the files are read, while `items` and `directives` keep
/// describing the one file's own lines (issue #45).
@Suite("a journal holds the files its include lines name") struct IncludeModelTests {
    static func entry(_ description: String) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2024, month: 1, day: 1),
            description: description,
            postings: [
                Posting(accountName: "Expenses:Rent", amount: Amount(quantity: 10, commodity: "$")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -10, commodity: "$")),
            ],
        )
    }

    static func tree() throws -> Journal {
        let child = try Journal(items: [
            .accountDirective(AccountDirective(name: "Income:Salary")),
            .transaction(entry("B")),
        ])
        return try Journal(items: [
            .accountDirective(AccountDirective(name: "Assets:Checking")),
            .transaction(entry("A")),
            .include(IncludedFiles(line: "include b.journal", journals: [child])),
            .transaction(entry("C")),
        ])
    }

    @Test
    func `transactions walk into included files in document order`() throws {
        let journal = try Self.tree()
        #expect(journal.transactions.map(\.description) == ["A", "B", "C"])
        #expect(journal.accountDirectives.map(\.name) == ["Assets:Checking", "Income:Salary"])
        #expect(journal.accountDirective(named: "Income:Salary")?.name == "Income:Salary")
        #expect(journal.items.count == 4)
    }

    @Test
    func `directives lists an include line`() throws {
        #expect(try Self.tree().directives == ["include b.journal"])
    }

    @Test
    func `an include item encodes and decodes`() throws {
        let journal = try Self.tree()
        let decoded = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(journal))
        #expect(decoded.transactions.map(\.description) == ["A", "B", "C"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = try Journal(items: [.transaction(Self.entry("A"))])
        #expect(try encoder.encode(plain) == encoder.encode(["items": plain.items]))
    }

    @Test
    func `withoutLocation steps through an included file`() {
        let error = LedgerError.inJournal(
            line: 1,
            entry: nil,
            underlying: .inIncludedFile(
                "/x/b.journal",
                underlying: .inJournal(line: 2, entry: "2024-01-01 B", underlying: .invalidAmount("1x2")),
            ),
        )
        #expect(error.withoutLocation == .invalidAmount("1x2"))
        #expect(error.line == 1)
    }
}
