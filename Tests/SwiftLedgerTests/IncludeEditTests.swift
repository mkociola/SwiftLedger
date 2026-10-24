import Foundation
@testable import SwiftLedger
import Testing

/// An entry read from an included file belongs to that file: editing it
/// changes that file's text and no other, a rebuilt entry is written under
/// the declarations in force where the file is included, and each file keeps
/// its own line ending. A new entry goes to the top file (issue #45).
@Suite("an edit lands in the file it came from") struct IncludeEditTests {
    static let part = """
    2024-01-01 Opening balance
        Assets:Checking  $2500.00
        Equity:Opening

    2024-01-03 Salary
        Assets:Checking  $3000.00
        Income:Salary

    """

    static let top = "include part.journal\n\n2024-01-05 Rent\n    Expenses:Rent  $1200.00\n    Assets:Checking\n"

    /// The text of every file the journal holds, keyed by file name.
    static func texts(_ journal: Journal) -> [String: String] {
        let files = JournalSerializer().serializedFiles(journal)
        return Dictionary(files.map { ($0.file?.lastPathComponent ?? "", $0.text) }) { first, _ in first }
    }

    static func rebuilt(_ entry: Transaction, as description: String) throws -> Transaction {
        try Transaction(date: entry.date, description: description, postings: entry.postings)
    }

    /// A posting to the same account, written under the same name, for
    /// another amount in euros.
    static func posting(like posting: Posting, quantity: Decimal) -> Posting {
        var copy = Posting(accountName: posting.accountName, amount: Amount(quantity: quantity, commodity: "EUR"))
        copy.writtenAccountName = posting.writtenAccountName
        return copy
    }

    @Test
    func `replacing an entry from an included file changes that file only`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        var journal = try files.parse("top.journal")
        let opening = try #require(journal.transactions.first)
        let found = try journal.replace(.transaction(opening), with: .transaction(Self.rebuilt(opening, as: "Opened")))
        #expect(found)
        let texts = Self.texts(journal)
        #expect(texts["top.journal"] == Self.top)
        let part = try #require(texts["part.journal"])
        #expect(part.hasPrefix("2024-01-01 Opened\n"))
        #expect(part.hasSuffix("\n\n2024-01-03 Salary\n    Assets:Checking  $3000.00\n    Income:Salary\n"))
        #expect(JournalSerializer().serialize(journal) == Self.top)
    }

    @Test
    func `a rebuilt entry in an included file is written under the parent's declarations`() throws {
        let files = try JournalFiles([
            "top.journal": "apply account Top\ndecimal-mark ,\ninclude part.journal\n",
            "part.journal": "2024-01-01 In\n    a  3 EUR\n    b\n",
        ])
        defer { files.remove() }
        var journal = try files.parse("top.journal")
        let entry = try #require(journal.transactions.first)
        let half = try #require(Decimal(string: "2.5"))
        let edited = try Transaction(date: entry.date, description: "Edited", postings: [
            Self.posting(like: entry.postings[0], quantity: half),
            Self.posting(like: entry.postings[1], quantity: -half),
        ])
        let found = journal.replace(.transaction(entry), with: .transaction(edited))
        #expect(found)
        let part = try #require(Self.texts(journal)["part.journal"])
        #expect(!part.contains("Top:"))
        #expect(part.contains("2,5"))
        try files.write("part.journal", part)
        let reread = try #require(files.parse("top.journal").transactions.first)
        #expect(reread.postings.map(\.accountName) == ["Top:a", "Top:b"])
        #expect(reread.postings.first?.amount.quantity == half)
    }

    @Test
    func `removing an entry from an included file removes it there`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        var journal = try files.parse("top.journal")
        let salary = try #require(journal.transactions.first { $0.description == "Salary" })
        let found = journal.remove(.transaction(salary))
        #expect(found)
        #expect(journal.transactions.map(\.description) == ["Opening balance", "Rent"])
        #expect(Self.texts(journal)["part.journal"]?.contains("Salary") == false)
        #expect(Self.texts(journal)["top.journal"] == Self.top)
    }

    @Test
    func `remove and replace look in the top file first`() throws {
        let files = try JournalFiles([
            "top.journal": "include part.journal\n",
            "part.journal": "account Assets:Checking\n",
        ])
        defer { files.remove() }
        let directive = try AccountDirective(name: "Assets:Checking")
        var journal = try files.parse("top.journal")
        journal.append(.accountDirective(directive))
        var removed = journal
        let found = removed.remove(.accountDirective(directive))
        #expect(found)
        let untouched = ["top.journal": "include part.journal\n", "part.journal": "account Assets:Checking\n"]
        #expect(Self.texts(removed) == untouched)
        var byName = journal
        let removedByName = byName.removeAccountDirective(named: "Assets:Checking")
        #expect(removedByName == directive)
        #expect(Self.texts(byName) == Self.texts(removed))
        var replaced = journal
        let typed = try AccountDirective(name: "Assets:Checking", type: .asset)
        let replacedFound = replaced.replace(.accountDirective(directive), with: .accountDirective(typed))
        #expect(replacedFound)
        #expect(Self.texts(replaced)["part.journal"] == "account Assets:Checking\n")
    }

    @Test(arguments: [(top: "\r\n", part: "\n"), (top: "\n", part: "\r\n")])
    func `each file keeps its own line ending`(endings: (top: String, part: String)) throws {
        let top = Self.top.replacingOccurrences(of: "\n", with: endings.top)
        let files = try JournalFiles([
            "top.journal": top,
            "part.journal": Self.part.replacingOccurrences(of: "\n", with: endings.part),
        ])
        defer { files.remove() }
        var journal = try files.parse("top.journal")
        let opening = try #require(journal.transactions.first)
        let found = try journal.replace(.transaction(opening), with: .transaction(Self.rebuilt(opening, as: "Opened")))
        #expect(found)
        let texts = Self.texts(journal)
        #expect(texts["top.journal"] == top)
        let part = try #require(texts["part.journal"])
        #expect(part.unicodeScalars.contains("\r") == (endings.part == "\r\n"))
        #expect(part.hasPrefix("2024-01-01 Opened" + endings.part))
    }

    @Test
    func `append goes to the top file`() throws {
        let files = try JournalFiles(["top.journal": Self.top, "part.journal": Self.part])
        defer { files.remove() }
        var journal = try files.parse("top.journal")
        let opening = try #require(journal.transactions.first)
        try journal.append(.transaction(Self.rebuilt(opening, as: "Appended")))
        let texts = Self.texts(journal)
        #expect(texts["part.journal"] == Self.part)
        #expect(texts["top.journal"]?.contains("Appended") == true)
        #expect(journal.transactions.last?.description == "Appended")
    }
}
