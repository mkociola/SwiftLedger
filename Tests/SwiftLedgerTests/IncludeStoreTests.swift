import Foundation
@testable import SwiftLedger
import Testing

/// `PlainTextJournalStore` loads a journal through its `include` lines and
/// saves each file whose text changed, leaving every other file alone: an
/// included file the user did not edit keeps its bytes and its modification
/// date, and one edited in another app since the load is not overwritten
/// (issue #45).
@Suite("the store writes each changed file of an included journal") struct IncludeStoreTests {
    static let part = IncludeEditTests.part
    static let top = IncludeEditTests.top

    static func manager(_ files: JournalFiles) throws -> LedgerManager {
        try LedgerManager(store: PlainTextJournalStore(url: files.url("top.journal")))
    }

    static func rent(_ description: String) throws -> Transaction {
        let dollars = { Amount(quantity: $0, commodity: "$", commodityIsPrefix: true) }
        return try Transaction(
            date: JournalDate(year: 2024, month: 2, day: 1),
            description: description,
            postings: [
                Posting(accountName: "Expenses:Rent", amount: dollars(5)),
                Posting(accountName: "Assets:Checking", amount: dollars(-5)),
            ],
        )
    }

    @Test
    func `loading a file follows its includes`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        #expect(manager.balance(for: "Assets:Checking").map(\.quantity) == [4300])
    }

    @Test
    func `a journal with no include saves exactly as before`() throws {
        let files = try JournalFiles(["top.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        try manager.add(.transaction(Self.rent("Rent")))
        #expect(try files.read("top.journal") == JournalSerializer().serialize(manager.currentJournal))
        #expect(try files.read("top.journal").hasPrefix(Self.part))
        let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(names == ["top.journal"])
    }

    @Test
    func `saving writes the included file that changed`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let opening = try #require(manager.currentJournal.transactions.first)
        try manager.replace(.transaction(opening), with: .transaction(IncludeEditTests.rebuilt(opening, as: "Opened")))
        #expect(try files.read("part.journal").hasPrefix("2024-01-01 Opened\n"))
        #expect(try files.read("top.journal") == Self.top)
        #expect(try Self.manager(files).currentJournal.transactions.first?.description == "Opened")
    }

    @Test
    func `saving leaves an unchanged included file alone`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let past = Date(timeIntervalSince1970: 946_684_800)
        let path = files.url("part.journal").path
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        let manager = try Self.manager(files)
        try manager.add(.transaction(Self.rent("Rent again")))
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == past)
        #expect(try files.read("part.journal") == Self.part)
        #expect(try files.read("top.journal").contains("Rent again"))
    }

    @Test
    func `an included file changed on disk by someone else is not overwritten`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let outside = Self.part + "\n2024-01-04 Added elsewhere\n    Expenses:Rent  $1.00\n    Assets:Checking\n"
        try files.write("part.journal", outside)
        try manager.add(.transaction(Self.rent("Rent again")))
        #expect(try files.read("part.journal") == outside)
    }

    @Test
    func `an edit in a file included twice is refused`() throws {
        let top = "include part.journal\ninclude part.journal\n"
        let files = try JournalFiles(["top.journal": top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let before = manager.currentJournal
        let opening = try #require(before.transactions.first)
        let opened = try IncludeEditTests.rebuilt(opening, as: "Opened")
        let error = try #require(throws: LedgerError.self) {
            try manager.replace(.transaction(opening), with: .transaction(opened))
        }
        guard case .storeError = error else {
            Issue.record("expected a store error, got \(error)")
            return
        }
        #expect(try files.read("part.journal") == Self.part)
        #expect(try files.read("top.journal") == top)
        #expect(manager.currentJournal == before)
    }
}
