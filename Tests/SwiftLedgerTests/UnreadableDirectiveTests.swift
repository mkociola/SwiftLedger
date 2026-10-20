@testable import SwiftLedger
import Testing

/// A `.directive` handed to `LedgerManager` was checked for a line break and
/// nothing else, so `add(.directive("D xyz"))` saved a file the next load
/// refuses at that line, as hledger refuses it (issue #130). The manager now
/// reads the journal as it would be saved before the store sees it, so a
/// directive the parser refuses, wherever it lands, is refused with the
/// parser's own error and nothing is written. Which lines those are is the
/// parser's business; this suite pins the gate with shapes the parser refuses
/// today and one it reads.
@Suite("unreadable directives in LedgerManager") struct UnreadableDirectiveTests {
    /// A `D` or `decimal-mark` line hledger cannot read, and an indented
    /// line appended where nothing above it can own it.
    @Test(arguments: ["D xyz", "decimal-mark x", "    note under nothing"])
    func `add refuses a directive the next parse refuses and saves nothing`(line: String) throws {
        let store = InMemoryLedgerStore()
        let manager = try LedgerManager(store: store)
        #expect(throws: LedgerError.self) { try manager.add(.directive(line)) }
        #expect(try store.load().journal.items.isEmpty)
    }

    @Test
    func `replace refuses a directive the next parse refuses and keeps the original`() throws {
        let store = InMemoryLedgerStore()
        let manager = try LedgerManager(store: store)
        let original = JournalItem.directive("include accounts.ledger")
        try manager.add(original)
        #expect(throws: LedgerError.self) { try manager.replace(original, with: .directive("D xyz")) }
        #expect(try store.load().journal.items == [original])
    }

    /// Where the line lands decides: appended to a journal that ends inside
    /// an open `comment` block, the same text is text, and is saved.
    @Test
    func `a directive appended inside an open comment block is text and is saved`() throws {
        let store = try InMemoryLedgerStore(ledger: Ledger(journal: JournalParser().parse("comment\n")))
        let manager = try LedgerManager(store: store)
        try manager.add(.directive("D xyz"))
        #expect(try store.load().journal.directives == ["comment", "D xyz"])
    }
}
