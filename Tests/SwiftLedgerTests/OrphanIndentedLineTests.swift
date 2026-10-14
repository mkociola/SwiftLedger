@testable import SwiftLedger
import Testing

/// An indented line outside every entry has to belong to the directive above
/// it, as a `commodity` or `account` block's subdirectives do. One that
/// belongs to nothing, most often a posting a blank line cut off from its
/// entry, is refused at its line, as hledger refuses it, rather than kept as
/// a directive nobody reads and left out of every report. Issue #92.
@Suite("indented lines that belong to nothing") struct OrphanIndentedLineTests {
    /// A journal and the line hledger refuses it at.
    struct Refused {
        let text: String
        let line: Int
    }

    /// Three lines, an entry with no blank line under it.
    private static let lunch = "2026-01-01 Lunch\n    Expenses:Food  $5.00\n    Assets:Checking\n"

    static let refused = [
        // A blank line ends the entry, and the posting under it is nobody's.
        Refused(text: lunch + "\n    Assets:Savings  $1.00\n", line: 5),
        // A line of nothing but spaces ends it just the same.
        Refused(text: lunch + "    \n    Assets:Savings  $1.00", line: 5),
        Refused(text: "    Assets:Savings  $1.00\n", line: 1),
        Refused(text: "\tAssets:Savings  $1.00\n", line: 1),
        Refused(text: "\n    Assets:Savings\n", line: 2),
        Refused(text: "P 2026-01-01 € $1.10\n    Assets:Savings\n", line: 2),
        Refused(text: "include other.journal\n    Assets:Savings\n", line: 2),
        Refused(text: "Y 2026\n    Assets:Savings\n", line: 2),
        Refused(text: "decimal-mark .\n    Assets:Savings\n", line: 2),
        Refused(text: "alias checking=Assets:Checking\n    Assets:Savings\n", line: 2),
        Refused(text: "; a note\n    Assets:Savings\n", line: 2),
        Refused(text: "comment\nnotes\nend comment\n    Assets:Savings\n", line: 4),
        // A blank line ends a `commodity` block, and so does a comment at
        // the margin.
        Refused(text: "commodity $\n\n    format $1,000.00\n", line: 3),
        Refused(text: "commodity $\n; a note\n    format $1,000.00\n", line: 3),
        // The one-line form states its style on the line and has no block.
        Refused(text: "commodity $1,000.00\n    note dollars\n", line: 2),
        // A periodic or automated entry ends at a whitespace-only line, as a
        // dated one does.
        Refused(text: "~ monthly\n    Expenses:Rent  $40.00\n    \n    Assets:Checking\n", line: 4),
        Refused(text: "= Expenses:Food\n    (Budget:Food)  *-1\n\n    (Budget:Rest)  *-1\n", line: 4),
    ]

    @Test(arguments: Self.refused)
    func `an indented line nothing above can own is refused at its line`(journal: Refused) throws {
        let error = try #require(throws: LedgerError.self) {
            try JournalParser().parse(journal.text)
        }
        #expect(error.line == journal.line)
    }

    static let read = [
        "commodity $\n    format $1,000.00\n    note dollars\n",
        "commodity\t$  ; dollars\n    format $1,000.00\n",
        "commodity \"AAPL 2\"\n    note shares\n",
        // hledger counts only an ASCII digit as part of a number.
        "commodity m²\n    note area\n",
        "account Assets:Checking\n    note current account\n    type A\n",
        "account Assets:Checking  ; main\n\tnote current account\n",
        "payee Grocer\n    note corner shop\n",
        "tag trip\n    note a tag\n",
        // A `commodity` or `account` block reads past a whitespace-only line
        // and past an indented comment.
        "commodity $\n    \n  \n    format $1,000.00\n",
        "account Assets:Checking\n    ; a note\n    note current account\n",
        "account Assets:Checking\n    \n    note current account\naccount Assets:Savings\n    note savings\n",
        "~ monthly\n    Expenses:Rent  $40.00\n    Assets:Checking\n",
        "= Expenses:Food\n    (Budget:Food)  *-1\n",
        // An indented comment belongs anywhere.
        "    ; a note\n",
        "2026-01-01 Lunch\n    Expenses:Food  $5.00\n    Assets:Checking\n\n    ; a note\n",
    ]

    @Test(arguments: Self.read)
    func `an indented line under a directive that owns it is read and written back`(text: String) throws {
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
    }
}
