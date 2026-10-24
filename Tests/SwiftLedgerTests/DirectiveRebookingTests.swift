@testable import SwiftLedger
import Testing

/// An `alias` or `apply account` line decides the account every entry below
/// it is booked under, so editing one through `LedgerManager` changes what
/// those entries mean. The manager used to save the edit and keep its old
/// reading in memory, so balances disagreed with the file until `reload()`
/// (issue #145). It now keeps the reading the saved file gives, under the
/// ids the caller already holds.
@Suite("a directive edit rebooks the entries below it") struct DirectiveRebookingTests {
    static let journal = """
    alias checking = Assets:Checking

    2024-01-01 Rent
        Expenses:Rent    $1200.00
        checking

    apply account Personal

    2024-01-02 Lunch
        Expenses:Food    $15.00
        Assets:Cash

    end apply account
    """

    private static func manager() throws -> (LedgerManager, InMemoryLedgerStore) {
        let store = try InMemoryLedgerStore(ledger: Ledger(journal: JournalParser().parse(journal)))
        return try (LedgerManager(store: store), store)
    }

    @Test
    func `replacing an alias rebooks the entries below it under their old ids`() throws {
        let (manager, _) = try Self.manager()
        let rent = try #require(manager.currentJournal.transactions.first)
        try manager.replace(
            .directive("alias checking = Assets:Checking"), with: .directive("alias checking = Assets:Joint"),
        )
        #expect(manager.balance(for: "Assets:Joint").map(\.quantity) == [-1200])
        #expect(manager.balance(for: "Assets:Checking").isEmpty)
        let rebooked = try #require(manager.currentJournal.transactions.first)
        #expect(rebooked.id == rent.id)
        #expect(rebooked.postings.last?.writtenAccountName == "checking")
    }

    /// The lunch is untouched by the alias, so the value the caller holds
    /// still names it, and can be replaced.
    @Test
    func `an entry the edit does not reach is still the value the caller holds`() throws {
        let (manager, _) = try Self.manager()
        let lunch = try #require(manager.currentJournal.transactions.last)
        let removed = try manager.remove(.directive("alias checking = Assets:Checking"))
        #expect(removed)
        #expect(manager.balance(for: "checking").map(\.quantity) == [-1200])
        #expect(manager.currentJournal.transactions.last == lunch)
    }

    /// Without its opening line, the `end apply account` below closes
    /// nothing, and the file would not load again, so nothing is saved.
    @Test
    func `removing a directive the file needs to load is refused and saves nothing`() throws {
        let (manager, store) = try Self.manager()
        #expect(throws: LedgerError.self) {
            try manager.remove(.directive("apply account Personal"))
        }
        #expect(try store.load().journal.directives.contains("apply account Personal"))
        #expect(manager.balance(for: "Personal:Assets:Cash").map(\.quantity) == [-15])
    }
}
