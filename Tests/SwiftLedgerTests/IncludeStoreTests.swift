import Foundation
@testable import SwiftLedger
import Testing

/// `PlainTextJournalStore` loads a journal through its `include` lines and
/// saves each file whose text changed, leaving every other file alone: an
/// included file the user did not edit keeps its bytes and its modification
/// date, and no file edited in another app since the store last read it is
/// overwritten: the save is refused instead (issue #45).
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
    func `a staging file a crash left behind is not read by a glob`() throws {
        let files = try JournalFiles(["top.journal": "include 2024/*\n", "2024/jan.journal": Self.part])
        defer { files.remove() }
        let staged = PlainTextJournalStore.stagingURL(for: files.url("2024/jan.journal"))
        try Data(Self.part.utf8).write(to: staged)
        let manager = try Self.manager(files)
        #expect(manager.balance(for: "Assets:Checking").map(\.quantity) == [5500])
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

    /// A file that mixes line endings is written back in one, so its text
    /// never matches what was read. Nobody edited it, so it is not written.
    @Test
    func `an unedited included file that does not round-trip byte for byte is left alone`() throws {
        let mixed = "2024-01-01 Opening balance\r\n    Assets:Checking  $2500.00\n    Equity:Opening\n"
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": mixed])
        defer { files.remove() }
        let manager = try Self.manager(files)
        try manager.add(.transaction(Self.rent("Rent again")))
        #expect(try Data(contentsOf: files.url("part.journal")) == Data(mixed.utf8))
    }

    /// An include line added through the manager reads its file from disk.
    /// Edited elsewhere afterwards and not here, the file keeps the outside
    /// edit when the journal is next saved.
    @Test
    func `a file included after the load and edited elsewhere is not overwritten`() throws {
        let files = try JournalFiles(["top.journal": Self.part, "child.journal": IncludeManagerTests.entry("Child")])
        defer { files.remove() }
        let manager = try Self.manager(files)
        try manager.add(.directive("include child.journal"))
        let outside = IncludeManagerTests.entry("Child") + "\n" + IncludeManagerTests.entry("Elsewhere")
        try files.write("child.journal", outside)
        try manager.add(.transaction(Self.rent("Rent again")))
        #expect(try files.read("child.journal") == outside)
    }

    /// Once an edit made here is saved, the file is not written again until
    /// it is edited here again, so a later outside edit survives.
    @Test
    func `an included file edited here and then elsewhere keeps the outside edit`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let opening = try #require(manager.currentJournal.transactions.first)
        try manager.replace(.transaction(opening), with: .transaction(IncludeEditTests.rebuilt(opening, as: "Opened")))
        let outside = try files.read("part.journal") + "\n" + IncludeManagerTests.entry("Elsewhere")
        try files.write("part.journal", outside)
        try manager.add(.transaction(Self.rent("Rent again")))
        #expect(try files.read("part.journal") == outside)
    }

    /// Asserts `save` was refused with a store error, that each file holds
    /// `disk[name]` byte for byte, and that memory is still `before`.
    static func expectRefused(
        _ files: JournalFiles,
        _ manager: LedgerManager,
        holding disk: [String: String],
        unchangedFrom before: Journal,
        _ save: () throws -> Void,
    ) throws {
        let error = try #require(throws: LedgerError.self) { try save() }
        guard case let .storeError(message) = error else {
            Issue.record("expected a store error, got \(error)")
            return
        }
        #expect(message.contains("has changed on disk"))
        for (name, text) in disk {
            #expect(try Data(contentsOf: files.url(name)) == Data(text.utf8))
        }
        #expect(manager.currentJournal == before)
    }

    /// The outside edit the app could not reload, because it does not parse,
    /// is the case nothing else catches: the snapshot is still the old text.
    @Test
    func `a save over a top file changed on disk to text that does not parse is refused`() throws {
        let files = try JournalFiles(["top.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let before = manager.currentJournal
        let outside = Self.part + "\n2024-01-04 Half typed\n    Expenses:Rent  $1.00\n    Assets:Checking  $2.00\n"
        try files.write("top.journal", outside)
        #expect(throws: LedgerError.self) { try manager.reload() }
        try Self.expectRefused(files, manager, holding: ["top.journal": outside], unchangedFrom: before) {
            try manager.add(.transaction(Self.rent("Rent again")))
        }
    }

    @Test
    func `an edit in an included file changed on disk since the load is refused`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let before = manager.currentJournal
        let outside = Self.part + "\n" + IncludeManagerTests.entry("Elsewhere")
        try files.write("part.journal", outside)
        let opening = try #require(before.transactions.first)
        let opened = try IncludeEditTests.rebuilt(opening, as: "Opened")
        let disk = ["top.journal": Self.top, "part.journal": outside]
        try Self.expectRefused(files, manager, holding: disk, unchangedFrom: before) {
            try manager.replace(.transaction(opening), with: .transaction(opened))
        }
    }

    /// A file that is gone, or cannot be read back, is not what the store last
    /// read either: the save is refused rather than quietly recreating it.
    @Test
    func `a save over a top file that can no longer be read is refused`() throws {
        let files = try JournalFiles(["top.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let before = manager.currentJournal
        try FileManager.default.removeItem(at: files.url("top.journal"))
        try Self.expectRefused(files, manager, holding: [:], unchangedFrom: before) {
            try manager.add(.transaction(Self.rent("Rent again")))
        }
        #expect(!FileManager.default.fileExists(atPath: files.url("top.journal").path))
    }

    @Test
    func `after a reload the refused save goes through and keeps the outside edit`() throws {
        let files = try JournalFiles(["top.journal": Self.part])
        defer { files.remove() }
        let manager = try Self.manager(files)
        let outside = Self.part + "\n" + IncludeManagerTests.entry("Elsewhere")
        try files.write("top.journal", outside)
        #expect(throws: LedgerError.self) { try manager.add(.transaction(Self.rent("Rent again"))) }
        try manager.reload()
        try manager.add(.transaction(Self.rent("Rent again")))
        let saved = try files.read("top.journal")
        #expect(saved.hasPrefix(outside))
        #expect(saved.contains("Rent again"))
    }
}
