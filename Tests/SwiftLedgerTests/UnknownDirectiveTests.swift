import Foundation
@testable import SwiftLedger
import Testing

/// A line at the margin that opens with no word hledger reads is a typo
/// hledger stops at, and the parser used to keep it verbatim: `foo bar`
/// loaded, and `decimal-markx ,` declared no comma, so every `€1.000` below
/// it was a euro rather than a thousand, without a word (issue #104). The
/// parser now refuses such a line at its line. The refusals are pinned
/// against hledger 1.52.4 in the three `directive-unknown-*` journals, and
/// the lines hledger reads and SwiftLedger keeps in `directive-keywords`.
@Suite("a line opening with no known word") struct UnknownDirectiveTests {
    /// Each opens with a word hledger reads no directive from: a word of its
    /// own, a keyword with a letter stuck to it, punctuation, or a `!` with a
    /// gap or a stranger after it. One it reads a keyword from, `yearx`, is
    /// refused by that directive's own rule, at the same line.
    @Test(arguments: [
        "foo bar", "decimal-markx ,", "commodityx", "includex foo", "aliasx a = b", "yearx 2024",
        "accountx Foo", "$foo", "-foo", "\"foo\"", "é foo", "!foo", "! include foo.journal",
    ])
    func `a line opening with no known word refuses the file at its line`(line: String) {
        let text = "; first\n\(line)\n\n2024-01-02 ok\n    Expenses:Rent    $1.00\n    Assets:Checking\n"
        #expect { try JournalParser().parse(text) } throws: { ($0 as? LedgerError)?.line == 2 }
    }

    /// Each is a line hledger reads, whether it models it or not: its own
    /// directives, the ledger-cli ones it passes over, the single-letter ones
    /// with or without a gap, a `!` straight in front of a keyword, a tab
    /// after the keyword, and a `--` line. Every one is kept as it came.
    @Test(arguments: [
        "include foo.journal", "!include foo.journal", "alias a = b", "end aliases", "apply account Foo",
        "end apply account", "payee Foo", "tag foo", "end tag", "P 2024-01-01 $ 1", "P2024-01-01 $ 1",
        "N $", "C 1 $ = 1 USD", "A assets", "define x=1", "bucket assets", "assert true", "check true",
        "eval 1", "expr 1", "python", "value x", "capture x y", "apply fixed $ 1", "end apply fixed",
        "apply tag foo", "end apply tag", "--foo", "include\tfoo.journal", "~ monthly", "= expenses",
        "!D $1.00",
    ])
    func `a line opening with a word hledger reads is kept`(line: String) throws {
        let text = "\(line)\n\n2024-01-02 ok\n    Expenses:Rent    $1.00\n    Assets:Checking\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.directives == [line])
        #expect(JournalSerializer().serialize(journal) == text)
    }
}
