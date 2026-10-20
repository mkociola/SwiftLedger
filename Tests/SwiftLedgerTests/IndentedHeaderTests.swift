import Foundation
@testable import SwiftLedger
import Testing

/// An indented `account` line or dated line used to be read as a declaration
/// or an entry wherever it stood, since both branches of `parse` looked at
/// the line with its indentation taken off. hledger refuses either outside
/// every block, and under an `account` or `commodity` block skips it as a
/// subdirective (issue #118). Both branches read the line as written now, so
/// an indented one reaches the branch that knows what stands above it.
/// Pinned against hledger 1.52.4 in `indented-account-line`,
/// `indented-entry` and `indented-lines-under-block`.
@Suite("indented account lines and dated headers") struct IndentedHeaderTests {
    /// Outside every block, each is refused at its own line: the `account`
    /// line a blank line cut off from the entry above, and the dated line
    /// that opens the file.
    @Test(arguments: [
        ("2024-01-01 Rent\n    Expenses:Rent  $40.00\n    Assets:Checking\n\n    account Assets:Savings\n", 5),
        ("    2024-01-01 Rent\n        Expenses:Rent  $40.00\n        Assets:Checking\n", 1),
    ])
    func `outside every block an indented account line or dated line refuses the file`(
        text: String, line: Int,
    ) {
        #expect { try JournalParser().parse(text) } throws: { ($0 as? LedgerError)?.line == line }
    }

    /// Under a block, the same lines are subdirectives: kept as they came,
    /// declaring no account and booking no entry, as hledger skips them.
    @Test(arguments: ["account Assets:Checking", "commodity $"])
    func `under a block an indented account line or dated line is a subdirective`(block: String) throws {
        let text = "\(block)\n    account Assets:Savings\n    2024-01-01 Parked\n        Expenses:Rent  $40.00\n"
            + "        Assets:Checking\n\n2024-01-02 Rent\n    Expenses:Rent  $40.00\n    Assets:Checking\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.map(\.description) == ["Rent"])
        #expect(!journal.accountDirectives.contains { $0.name == "Assets:Savings" })
        #expect(JournalSerializer().serialize(journal) == text)
    }
}
