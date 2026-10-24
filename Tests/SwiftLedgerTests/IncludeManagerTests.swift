import Foundation
@testable import SwiftLedger
import Testing

/// A directive edit makes `LedgerManager` re-read the journal as the saved
/// files read it. For a journal read from a file that means re-reading every
/// file it includes, following an `include` line just added, and handing each
/// file's entries back the ids they had, so a value the caller holds still
/// finds its entry (issue #45).
@Suite("the manager re-reads every included file after a directive edit") struct IncludeManagerTests {
    static let part = IncludeEditTests.part

    static func manager(_ files: JournalFiles) throws -> LedgerManager {
        try LedgerManager(store: PlainTextJournalStore(url: files.url("top.journal")))
    }

    static func entry(_ description: String) -> String {
        "2024-01-0\(description.count % 9 + 1) \(description)\n    Expenses:Rent  $1.00\n    Assets:Checking\n"
    }

    @Test
    func `adding an include line follows it`() throws {
        let files = try JournalFiles(["top.journal": Self.entry("Rent"), "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        try manager.add(.directive("include part.journal"))
        #expect(manager.currentJournal.transactions.map(\.description) == ["Rent", "Opening balance", "Salary"])
        #expect(manager.currentJournal.items.contains { if case .include = $0 { true } else { false } })
        #expect(try files.read("top.journal").hasSuffix("\ninclude part.journal"))
    }

    @Test
    func `removing a directive line rebooks entries in included files`() throws {
        let files = try JournalFiles([
            "top.journal": "apply account Top\ninclude part.journal\n",
            "part.journal": "2024-01-01 In\n    a  $1.00\n    b\n",
        ])
        defer { files.remove() }
        let manager = try Self.manager(files)
        #expect(manager.currentJournal.transactions.first?.postings.first?.accountName == "Top:a")
        try manager.remove(.directive("apply account Top"))
        #expect(manager.currentJournal.transactions.first?.postings.first?.accountName == "a")
    }

    @Test
    func `ids survive a reload per file`() throws {
        let files = try JournalFiles([
            "top.journal": "; the parts\ninclude part.journal\n\n" + Self.entry("Rent"),
            "part.journal": Self.part,
            "second.journal": Self.entry("Second"),
        ])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let salary = try #require(manager.currentJournal.transactions.first { $0.description == "Salary" })
        let rent = try #require(manager.currentJournal.transactions.first { $0.description == "Rent" })
        // An include line read ahead of every other entry: carried over by
        // position, each id would land on the entry before it.
        let second = JournalItem.include(IncludedFiles(line: "include second.journal", journals: []))
        try manager.replace(.comment("; the parts"), with: second)
        let order = manager.currentJournal.transactions.map(\.description)
        #expect(order == ["Second", "Opening balance", "Salary", "Rent"])
        let pay = try IncludeEditTests.rebuilt(salary, as: "Pay")
        let lease = try IncludeEditTests.rebuilt(rent, as: "Lease")
        #expect(try manager.replace(.transaction(salary), with: .transaction(pay)))
        #expect(try manager.replace(.transaction(rent), with: .transaction(lease)))
        #expect(try files.read("part.journal").contains("Pay"))
        #expect(try files.read("top.journal").contains("Lease"))
    }

    @Test
    func `removing an include line drops its entries and keeps other ids`() throws {
        let files = try JournalFiles([
            "top.journal": "include a.journal\ninclude b.journal\n\n" + Self.entry("Rent"),
            "a.journal": Self.entry("A"),
            "b.journal": Self.entry("B"),
        ])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let journal = manager.currentJournal
        let first = try #require(journal.items.first)
        let held = journal.transactions.filter { $0.description != "A" }
        try manager.remove(first)
        #expect(manager.currentJournal.transactions.map(\.description) == ["B", "Rent"])
        #expect(manager.currentJournal.transactions == held)
        #expect(try files.read("top.journal").hasPrefix("include b.journal\n"))
    }

    @Test
    func `a transaction built in code replacing one in an included file balances against that file's formats`() throws {
        let files = try JournalFiles([
            "top.journal": "include part.journal\n\n2024-01-05 Rent\n    Expenses:Rent  €12.00\n    Assets:Checking\n",
            "part.journal": "2024-01-01 Opening\n    Assets:Checking  €10\n    Equity:Opening\n",
        ])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let opening = try #require(manager.currentJournal.transactions.first)
        // 3 × €3.33 is €9.99: within half a euro, which is all the part's
        // whole-euro amounts claim, and off by a cent at the top file's two
        // places.
        let euros = { Amount(quantity: $0, commodity: "€", commodityIsPrefix: true) }
        let bought = try Transaction(date: opening.date, description: "Bought", postings: [
            Posting(
                accountName: "Assets:Broker",
                amount: Amount(quantity: 3, commodity: "AAPL"),
                price: .perUnit(euros(#require(Decimal(string: "3.33")))),
            ),
            Posting(accountName: "Assets:Checking", amount: euros(-10)),
        ])
        #expect(try manager.replace(.transaction(opening), with: .transaction(bought)))
        #expect(throws: LedgerError.self) { try manager.add(.transaction(bought)) }
    }

    @Test
    func `a hand-built include item is read from disk`() throws {
        let files = try JournalFiles(["top.journal": Self.entry("Rent"), "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        try manager.add(.include(IncludedFiles(line: "include part.journal", journals: [])))
        #expect(manager.currentJournal.transactions.map(\.description) == ["Rent", "Opening balance", "Salary"])
    }
}
