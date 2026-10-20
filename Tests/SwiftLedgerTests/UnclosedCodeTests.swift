import Foundation
@testable import SwiftLedger
import Testing

/// Where the code would be, a `(` opens one that runs to the first `)` on
/// the line, and hledger refuses the line when no `)` follows. The parser
/// used to leave such a `(` in the description, so `(CHQ1 Rent` loaded as an
/// entry described `(CHQ1 Rent`, where a missing `)` is a typo hledger
/// points at (issue #101). `transaction-code-unclosed.journal` pins the
/// refusal against hledger 1.52.4, and `transaction-code-parentheses.journal`
/// the shapes that still load: a `(` in a description, after a code that
/// closed, an empty code and one with spaces inside its parentheses.
@Suite("an unclosed transaction code") struct UnclosedCodeTests {
    /// A `(` where the code would be, with no `)` after it on the line,
    /// refuses the file at that line, whatever else the line holds.
    @Test(arguments: [
        "2024-01-01 (CHQ1 Rent ; paid early", "2024-01-01 (CHQ1 Rent", "2024-01-01 (",
        "2024-01-01 ( Rent", "2024-01-01 * (CHQ1 Rent", "2024-01-01 (A ; B",
    ])
    func `a code with no closing parenthesis refuses the file`(header: String) {
        let text = "; a comment first\n\(header)\n    Expenses:Rent    $1.00\n    Assets:Checking\n"
        #expect { try JournalParser().parse(text) } throws: { error in
            guard let error = error as? LedgerError, error.line == 2,
                  case .parseError = error.withoutLocation else { return false }
            return true
        }
    }
}
