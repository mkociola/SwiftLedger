import Foundation
@testable import SwiftLedger
import Testing

/// A journal kept as one file per year under a top file of `include` lines
/// used to show only the top file's entries, with nothing to say the rest
/// existed. `JournalParser.parse(fileAt:)` now reads an included file where
/// the line stands, as hledger 1.52.4 does, and refuses one it cannot follow
/// (issue #45).
@Suite("include lines are followed when a file is parsed") struct IncludeTests {
    static let part = """
    2024-01-01 Opening balance
        Assets:Checking  $2500.00
        Equity:Opening

    """

    static func entry(_ description: String, day: Int = 1) -> String {
        """
        2024-01-\(day < 10 ? "0" : "")\(day) \(description)
            Expenses:Rent  $1.00
            Assets:Checking

        """
    }

    @Test
    func `an included file's entries are read at the include line`() throws {
        let top = "include part.journal\n\n2024-01-05 Rent\n    Expenses:Rent  $1200.00\n    Assets:Checking\n"
        let files = try JournalFiles(["top.journal": top, "part.journal": Self.part])
        defer { files.remove() }
        let journal = try files.parse("top.journal")
        #expect(Ledger(journal: journal).balance(for: "Assets:Checking").map(\.quantity) == [1300])
        #expect(journal.transactions.map(\.description) == ["Opening balance", "Rent"])
        #expect(journal.file?.path == files.url("top.journal").path)
        guard case let .include(included) = journal.items.first else {
            Issue.record("expected an include item, got \(String(describing: journal.items.first))")
            return
        }
        #expect(included.line == "include part.journal")
        #expect(included.journals.map(\.file?.path) == [files.url("part.journal").path])
    }

    @Test
    func `text parsing leaves an include line verbatim`() throws {
        let journal = try JournalParser().parse("include part.journal\n\n" + Self.entry("Rent"))
        #expect(journal.items.first == .directive("include part.journal"))
        #expect(journal.transactions.count == 1)
    }

    @Test
    func `a relative path is read from the including file's directory`() throws {
        let files = try JournalFiles([
            "top.journal": "include sub/b.journal\n",
            "sub/b.journal": "include deeper.journal\n" + Self.entry("B"),
            "sub/deeper.journal": Self.entry("Deeper"),
        ])
        defer { files.remove() }
        #expect(try files.parse("top.journal").transactions.map(\.description) == ["Deeper", "B"])
    }

    @Test(arguments: ["include part.journal  ; note", "include part.journal   ", "include part.journal;note",
                      "include\tpart.journal", "!include part.journal", "include journal:part.journal"])
    func `the path ends before a comment or trailing spaces`(line: String) throws {
        let files = try JournalFiles(["top.journal": line + "\n", "part.journal": Self.part])
        defer { files.remove() }
        #expect(try files.parse("top.journal").transactions.count == 1)
    }

    @Test
    func `a glob reads every match in sorted order, skipping the including file`() throws {
        let files = try JournalFiles([
            "all.journal": "include *.journal\n",
            "b.journal": Self.entry("b"),
            "a.journal": Self.entry("a"),
            "brackets.journal": "include [ab].journal\n",
            "deep.top": "include **/deep.journal\n",
            "x/y/deep.journal": Self.entry("deep"),
            ".hidden.journal": Self.entry("hidden"),
        ])
        defer { files.remove() }
        // `brackets.journal` matches the glob too, and reads `a` and `b` again.
        #expect(try files.parse("all.journal").transactions.map(\.description) == ["a", "b", "a", "b"])
        #expect(try files.parse("brackets.journal").transactions.map(\.description) == ["a", "b"])
        #expect(try files.parse("deep.top").transactions.map(\.description) == ["deep"])
    }

    @Test(arguments: ["include nope.journal", "include *.nothing", "include sub", "include rules:part.journal"])
    func `an include matching no file is refused`(line: String) throws {
        let files = try JournalFiles(["top.journal": line + "\n", "sub/x.journal": "", "part.journal": Self.part])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) { try files.parse("top.journal") }
        let path = String(line.dropFirst("include ".count))
        guard case let .unreadableInclude(written, _) = error.withoutLocation else {
            Issue.record("expected unreadableInclude, got \(error)")
            return
        }
        #expect(written == path)
        #expect(error.line == 1)
    }

    @Test
    func `an unreadable included file is refused`() throws {
        let files = try JournalFiles(["top.journal": "include part.journal\n", "part.journal": Self.part])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(fileAt: files.url("top.journal")) { url in
                guard url.lastPathComponent == "top.journal" else { throw CocoaError(.fileReadNoPermission) }
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        guard case .unreadableInclude("part.journal", _) = error.withoutLocation else {
            Issue.record("expected unreadableInclude, got \(error)")
            return
        }
    }

    @Test
    func `an include cycle is refused`() throws {
        let files = try JournalFiles([
            "a.journal": "include b.journal\n",
            "b.journal": Self.entry("B") + "include a.journal\n",
            "self.journal": "include self.journal\n" + Self.entry("Self"),
        ])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) { try files.parse("a.journal") }
        guard case let .inJournal(1, nil, .inIncludedFile(path, .parseError(line, _))) = error else {
            Issue.record("expected a cycle refused in b.journal, got \(error)")
            return
        }
        #expect(path == files.url("b.journal").path)
        #expect(line == 4)
        #expect(try files.parse("self.journal").transactions.map(\.description) == ["Self"])
    }

    @Test
    func `the same file included twice is read twice`() throws {
        let files = try JournalFiles([
            "top.journal": "include part.journal\ninclude part.journal\n",
            "part.journal": Self.part,
        ])
        defer { files.remove() }
        #expect(try files.parse("top.journal").transactions.count == 2)
    }

    @Test(arguments: ["include", "include   ", "include ; a comment"])
    func `include with no path is refused`(line: String) throws {
        let files = try JournalFiles(["top.journal": line + "\n"])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) { try files.parse("top.journal") }
        guard case .parseError(line: 1, _) = error else {
            Issue.record("expected a parse error at line 1, got \(error)")
            return
        }
    }

    @Test(arguments: ["include x.csv", "include x.CSV", "include x.timedot", "include x.timeclock",
                      "include x.tsv", "include x.ssv", "include timedot:x.journal", "include csv:x.journal"])
    func `a non-journal format is refused`(line: String) throws {
        let files = try JournalFiles([
            "top.journal": line + "\n",
            "x.journal": Self.part, "x.csv": Self.part, "x.CSV": Self.part, "x.timedot": Self.part,
            "x.timeclock": Self.part, "x.tsv": Self.part, "x.ssv": Self.part,
        ])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) { try files.parse("top.journal") }
        guard case .parseError(line: 1, _) = error else {
            Issue.record("expected a parse error at line 1, got \(error)")
            return
        }
    }

    @Test(arguments: ["include journal:x.csv", "include x.dat", "include x"])
    func `a journal prefix or another extension reads as a journal`(line: String) throws {
        let files = try JournalFiles([
            "top.journal": line + "\n", "x.csv": Self.part, "x.dat": Self.part, "x": Self.part,
        ])
        defer { files.remove() }
        #expect(try files.parse("top.journal").transactions.count == 1)
    }

    @Test
    func `an include inside a comment block is text`() throws {
        let files = try JournalFiles(["top.journal": "comment\ninclude nope.journal\nend comment\n"])
        defer { files.remove() }
        #expect(try files.parse("top.journal").directives.contains("include nope.journal"))
    }

    @Test
    func `an error inside an included file names that file and line`() throws {
        let files = try JournalFiles([
            "top.journal": "; the parts\ninclude part.journal\n",
            "part.journal": "2024-01-01 Bad\n    Assets:Checking  1x2\n    Equity:Opening\n",
        ])
        defer { files.remove() }
        let error = try #require(throws: LedgerError.self) { try files.parse("top.journal") }
        let expected = LedgerError.inJournal(
            line: 2,
            entry: nil,
            underlying: .inIncludedFile(
                files.url("part.journal").path,
                underlying: .inJournal(line: 2, entry: "2024-01-01 Bad", underlying: .invalidAmount("1x2")),
            ),
        )
        #expect(error == expected)
    }

    @Test
    func `an included file without a final newline is followed by the parent's entries`() throws {
        let files = try JournalFiles([
            "top.journal": "include part.journal\n" + Self.entry("After", day: 2),
            "part.journal": String(Self.entry("Part").dropLast()),
        ])
        defer { files.remove() }
        #expect(try files.parse("top.journal").transactions.map(\.description) == ["Part", "After"])
    }
}
