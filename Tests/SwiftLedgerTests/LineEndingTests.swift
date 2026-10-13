import Foundation
@testable import SwiftLedger
import Testing

/// A journal's items with each entry stood in for by the lines it was read
/// from. Every parse mints a new `Transaction.id`, so two readings of one
/// entry never compare equal, while their lines do.
private func shape(of journal: Journal) -> [JournalItem] {
    journal.items.map { item in
        if case let .transaction(transaction) = item { return .directive(transaction.sourceText ?? "") }
        return item
    }
}

/// The line ending is a layout property of the file, as the posting indent
/// and the amount margin are. `JournalParser` learns it and takes it off
/// every line, and `JournalSerializer` writes it back, so a journal kept on
/// Windows is read as the same journal kept anywhere else, and an entry
/// rebuilt in it does not come back as the one line in the file with a
/// different ending from its neighbours.
@Suite("line endings") struct LineEndingTests {
    /// One of everything the parser tells apart at the top level, ending in
    /// a line break as a saved file does.
    private static let lines = [
        "; household",
        "account Assets:Checking  ; main",
        "D $1,000.00",
        "",
        "2026-03-01 * Groceries  ; weekly shop",
        "    ; paid by card",
        "    Expenses:Food         $66.00",
        "    Assets:Checking",
        "",
        "2026-03-02 Rent",
        "    Expenses:Rent      $1,200.00",
        "    Assets:Checking   $-1,200.00",
        "",
    ]

    @Test
    func `a windows journal reads as the same journal with unix endings`() throws {
        let text = Self.lines.joined(separator: "\r\n")
        let journal = try JournalParser().parse(text)
        let unix = try JournalParser().parse(Self.lines.joined(separator: "\n"))
        #expect(journal.lineEnding == .windows)
        #expect(unix.lineEnding == .unix)

        // Item for item: the blank lines are `.blank` rather than a directive
        // holding a `\r`, the `D` line is the directive the file wrote, and
        // every entry keeps the lines it was read from without their endings.
        #expect(shape(of: journal) == shape(of: unix))
        #expect(journal.items[3] == .blank)
        #expect(journal.directives == ["D $1,000.00"])
        #expect(journal.transactions.map(\.postings) == unix.transactions.map(\.postings))
        #expect(journal.commodityFormats == unix.commodityFormats)
        #expect(journal.amountAlignment == unix.amountAlignment)

        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// The diff the style collector exists to prevent: one entry edited, and
    /// its lines the only ones in the file ending in a bare `\n`. An `account`
    /// line and an entry added to the journal are written from the model too
    /// and have to follow the file the same way.
    @Test
    func `an entry rebuilt in a windows journal is written with windows endings`() throws {
        var journal = try JournalParser().parse(Self.lines.joined(separator: "\r\n"))
        let rent = try #require(journal.transactions.last)
        let renamed = try Transaction(date: rent.date, description: "Rent, March", postings: rent.postings)
        let replaced = journal.replace(.transaction(rent), with: .transaction(renamed))
        #expect(replaced)
        try journal.append(.accountDirective(AccountDirective(name: "Expenses:Rent")))
        try journal.append(.transaction(Transaction(date: rent.date, description: "Deposit", postings: rent.postings)))

        var expected = Self.lines
        expected[9] = "2026-03-02 Rent, March"
        expected += [
            "account Expenses:Rent",
            "2026-03-02 Deposit",
            "    Expenses:Rent      $1,200.00",
            "    Assets:Checking   $-1,200.00",
        ]
        #expect(JournalSerializer().serialize(journal) == expected.joined(separator: "\r\n"))
    }

    /// A file that mixes endings is read as its dominant one and written back
    /// in it throughout, which is what an editor does with such a file. The
    /// `\r` comes off every line that has one whichever ending wins, so no
    /// field keeps it. An even split has no dominant ending and reads as
    /// Unix, the ending a journal built in code is written with.
    @Test(arguments: [
        (["2026-03-01 Lunch\r", "    Expenses:Food  $5\r", "    Assets:Checking", ""], LineEnding.windows),
        (["2026-03-01 Lunch", "    Expenses:Food  $5", "    Assets:Checking\r", ""], LineEnding.unix),
        (["account Assets:Checking\r", "account Expenses:Food", ""], LineEnding.unix),
    ])
    func `a file that mixes endings is read as its dominant one`(mixed: [String], dominant: LineEnding) throws {
        let journal = try JournalParser().parse(mixed.joined(separator: "\n"))
        #expect(journal.lineEnding == dominant)

        let clean = mixed.map { $0.replacingOccurrences(of: "\r", with: "") }
        let unmixed = try JournalParser().parse(clean.joined(separator: "\n"))
        #expect(shape(of: journal) == shape(of: unmixed))
        #expect(JournalSerializer().serialize(journal) == clean.joined(separator: dominant.rawValue))
    }

    /// What follows the last `\n` is not a line anything ended, so it has no
    /// say in which ending the file uses: a single line with a Windows ending
    /// is a Windows file, although the text splits into that line and an
    /// empty one.
    @Test
    func `a single line teaches its ending`() throws {
        #expect(try JournalParser().parse("; note\r\n").lineEnding == .windows)
        #expect(try JournalParser().parse("; note\n").lineEnding == .unix)
        #expect(try JournalParser().parse("; note").lineEnding == .unix)
        #expect(try JournalParser().parse("").lineEnding == .unix)
    }

    /// A file cut off between the two halves of its last line ending. hledger
    /// reads the line without the `\r`, so the account it names is the one
    /// the file names. The `\r` ended nothing, though, so it teaches nothing
    /// and is not written back.
    @Test
    func `a carriage return ending the file comes off its line`() throws {
        let text = "2026-03-01 Lunch\n    Expenses:Food  $5\n    Assets:Checking"
        let journal = try JournalParser().parse(text + "\r")
        #expect(journal.transactions.first?.postings.last?.accountName == "Assets:Checking")
        #expect(journal.lineEnding == .unix)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Classic Mac endings stay unsupported. With no `\n` anywhere the file is
    /// one line, and the `\r` inside it is a break in the description.
    @Test
    func `a file with carriage returns alone still refuses to load`() throws {
        let text = "2026-03-01 Lunch\r    Expenses:Food  $5\r    Assets:Checking  $-5\r"
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error.withoutLocation == .lineBreakInField("description"))
    }

    /// The ending describes one file's layout, as the amount margin does, so
    /// a journal that came from no file has none to keep and is written with
    /// Unix endings, as it always was.
    @Test
    func `a journal built in code or decoded from JSON is written with unix endings`() throws {
        #expect(Journal().lineEnding == .unix)

        let windows = try JournalParser().parse(Self.lines.joined(separator: "\r\n"))
        let decoded = try JSONDecoder().decode(Journal.self, from: JSONEncoder().encode(windows))
        #expect(decoded.lineEnding == .unix)
        #expect(!JournalSerializer().serialize(decoded).unicodeScalars.contains("\r"))
    }

    /// `JournalItem.comment` has no initialiser to refuse a break in, so the
    /// serializer writes each of its lines as a comment. It splits them as
    /// the parser splits a file, which leaves no `\r` behind for the journal's
    /// own ending to be written after: a Unix journal stays one, and a Windows
    /// journal does not get a line ending in `\r\r\n`.
    @Test(arguments: [LineEnding.unix, .windows])
    func `a comment built in code with a windows line break is written in the journal's ending`(
        ending: LineEnding,
    ) {
        let journal = Journal(items: [.comment("first\r\nsecond"), .blank], lineEnding: ending)
        #expect(JournalSerializer().serialize(journal) == "; first\(ending.rawValue); second\(ending.rawValue)")
    }

    /// A file converted twice ends its lines `\r\r\n`. One `\r` is the line
    /// ending and comes off; the other is a stray, kept on the line it stands
    /// on and written back with it, on a comment as on a directive.
    @Test
    func `a stray carriage return in front of a line ending is written back`() throws {
        let text = "; converted twice\r\r\ninclude other.journal\r\r\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.items == [.comment("; converted twice\r"), .directive("include other.journal\r"), .blank])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// A style directive on such a line is still read for what it declares,
    /// as hledger reads it: dropped without a word, it would leave the amounts
    /// below to the tie-break, and `€1.000` would be one euro rather than a
    /// thousand.
    @Test(arguments: ["commodity €1.000,00", "D €1.000,00", "decimal-mark ,"])
    func `a directive with a stray carriage return still declares its style`(directive: String) throws {
        let text = ["\(directive)\r", "", "2026-03-01 Opening", "    assets:bank  €1.000", "    equity:opening", ""]
            .joined(separator: "\r\n")
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.first?.amount.quantity == 1000)
        #expect(journal.directives == ["\(directive)\r"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// A `\r` anywhere but the end of its line ends nothing, and the file
    /// refuses to load wherever it lands, an amount included. hledger reads
    /// past this one, which is a divergence kept by choice
    /// (`amount-stray-cr` in `HledgerConformanceTests.knownDivergences`).
    @Test
    func `a carriage return after an amount refuses to load`() throws {
        let text = "2026-03-01 Lunch\r\n    Expenses:Food  $5\r  ; note\r\n    Assets:Checking\r\n"
        let error = try #require(throws: LedgerError.self) { try JournalParser().parse(text) }
        #expect(error == .inJournal(line: 2, entry: "2026-03-01 Lunch", underlying: .invalidAmount("$5\r")))
    }
}
