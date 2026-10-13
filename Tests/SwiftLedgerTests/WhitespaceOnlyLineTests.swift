@testable import SwiftLedger
import Testing

/// A line holding nothing but spaces or tabs is what an auto-indenting editor
/// leaves behind an entry. It reads as a blank line and is written back with
/// the whitespace it came with, so that saving a journal nobody edited does
/// not put a changed line in the diff. Issue #86.
@Suite("whitespace-only lines") struct WhitespaceOnlyLineTests {
    @Test(arguments: ["    ", "\t", " \t "], ["\n", "\r\n"])
    func `a whitespace-only line ends the entry and is written back as it came`(
        whitespace: String,
        ending: String,
    ) throws {
        let text = [
            "2026-03-01 Lunch",
            "    Expenses:Food  $5",
            "    Assets:Checking",
            whitespace,
            "2026-03-02 Tea",
            "    Expenses:Food  $2",
            "    Assets:Checking",
            "",
        ].joined(separator: ending)
        let journal = try JournalParser().parse(text)

        #expect(journal.transactions.map(\.description) == ["Lunch", "Tea"])
        #expect(journal.items[1] == .directive(whitespace))
        #expect(journal.items.last == .blank)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Inside a block comment the line is one more line of text, kept the same
    /// way, and the block still closes where it did.
    @Test
    func `a whitespace-only line inside a block comment is written back as it came`() throws {
        let text = "comment\nparked\n  \t\nend comment\n; after"
        let journal = try JournalParser().parse(text)

        #expect(journal.items[2] == .directive("  \t"))
        #expect(journal.items.last == .comment("; after"))
        #expect(JournalSerializer().serialize(journal) == text)
    }
}
