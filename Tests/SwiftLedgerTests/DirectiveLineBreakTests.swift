@testable import SwiftLedger
import Testing

/// Issue #72: a `.directive` is written back verbatim, so one holding a line
/// break is written as two lines, and the next parse books a dated second
/// line as an entry nobody wrote. `LedgerManager` refuses one before it saves.
@Suite("directive line break") struct DirectiveLineBreakTests {
    static let breaks = ["\n", "\r\n", "\r"]

    @Test(arguments: DirectiveLineBreakTests.breaks)
    func `add refuses a directive holding a line break and saves nothing`(lineBreak: String) throws {
        let store = InMemoryLedgerStore()
        let manager = try LedgerManager(store: store)
        let item = JournalItem.directive("include accounts.ledger\(lineBreak)2024-01-01 Injected")
        #expect(throws: LedgerError.lineBreakInField("directive")) {
            try manager.add(item)
        }
        #expect(try store.load().journal.items.isEmpty)
    }

    @Test(arguments: DirectiveLineBreakTests.breaks)
    func `replace refuses a directive holding a line break and keeps the original`(lineBreak: String) throws {
        let store = InMemoryLedgerStore()
        let manager = try LedgerManager(store: store)
        let original = JournalItem.directive("include accounts.ledger")
        try manager.add(original)
        let replacement = JournalItem.directive("include accounts.ledger\(lineBreak)2024-01-01 Injected")
        #expect(throws: LedgerError.lineBreakInField("directive")) {
            try manager.replace(original, with: replacement)
        }
        #expect(try store.load().journal.items == [original])
    }

    @Test
    func `a one-line directive is still added`() throws {
        let store = InMemoryLedgerStore()
        let manager = try LedgerManager(store: store)
        try manager.add(.directive("include accounts.ledger"))
        #expect(try store.load().journal.directives == ["include accounts.ledger"])
    }
}
