@testable import SwiftLedger
import Testing

/// hledger reads a block comment line by line and wants a newline after each
/// one, so a file whose last line belongs to a block and has none is refused
/// with "unexpected end of input, expecting newline", the closing keyword
/// included. SwiftLedger refuses the same files, pointing at that line,
/// rather than load a journal the reference tool will not open. Issue #66.
@Suite("block comments at the end of the file") struct BlockCommentEndOfFileTests {
    /// Four lines, the last of them blank, so a tail starts on line 5.
    private static let rent = "2026-01-02 Rent\n    Expenses:Rent    $40.00\n    Assets:Checking\n\n"

    /// The tail of a file, each ending on a line of a block with no newline
    /// after it, paired with the line the last of them sits on.
    struct Tail {
        let text: String
        let lastLine: Int
    }

    static let refused = [
        Tail(text: "comment\n2026-01-01 Parked\n    Expenses:Rent    $1.00\n    Assets:Checking", lastLine: 8),
        Tail(text: "comment", lastLine: 5),
        Tail(text: "comment\nnotes\nend comment", lastLine: 7),
        Tail(text: "test\nnotes\nend test  ", lastLine: 7),
        Tail(text: "comment\nnotes\n  \t", lastLine: 7),
        Tail(text: "comment\r\nnotes\r", lastLine: 6),
        Tail(text: "comment\nnotes\n\r", lastLine: 7),
    ]

    @Test(arguments: Self.refused)
    func `a block on the last line with no newline after it is refused at that line`(tail: Tail) throws {
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(Self.rent + tail.text)
        }
        #expect(error.line == tail.lastLine)
    }

    @Test(arguments: ["comment\nnotes\n", "comment\nnotes\nend comment\n", "comment\n"])
    func `a block on the last line followed by a newline is read`(tail: String) throws {
        let text = Self.rent + tail
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["Rent"])
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Only a block's own line needs the newline: once the block is closed,
    /// what follows it may end the file however it likes, as in hledger.
    @Test(arguments: ["; a note", "2026-01-03 Tea\n    Expenses:Food  $2\n    Assets:Checking"])
    func `a closed block followed by a line with no newline is read`(after: String) throws {
        let text = Self.rent + "comment\nnotes\nend comment\n" + after
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.description == "Rent")
        #expect(JournalSerializer().serialize(journal) == text)
    }
}
