import Foundation
@testable import SwiftLedger
import Testing

/// A bare commodity symbol holds none of the characters hledger quotes for:
/// a digit, whitespace, or one of `-+.@*{}="`. The parser used to take
/// whatever stood beside the number for the symbol, so `100 E R` loaded as
/// a hundred of a commodity called `E R` where hledger refuses the file,
/// and an entry built in code with such a symbol was once written bare into
/// a file hledger could not open (issue #112). A rebuilt amount has written
/// such a symbol in quotes since #38, and the parser now refuses it bare,
/// through the same rule. Each refusal is hledger 1.52.4's, pinned in the
/// `bare-symbol-*` journals; `bare-symbol-punctuation` holds the symbols
/// that still read bare, and the refused ones in quotes.
@Suite("bare commodity symbols") struct BareSymbolTests {
    static func posting(_ amount: String) throws -> Posting {
        let text = "2024-01-01 Rent\n    Expenses:Rent    \(amount)\n    Assets:Checking\n"
        return try #require(JournalParser().parse(text).transactions.first?.postings.first)
    }

    /// On either side of the number, a symbol holding one of the quoted
    /// characters is no amount, and the file is refused at the posting.
    @Test(arguments: [
        "100 E R", "100 E*R", "100 E{R", "100 E}R", "100 E-R", "100 E+R", "100 E.R", "100 E\"R",
        "E R100", "E R 100", "E*R100", "E{R100", "E}R100", "E\"R100",
    ])
    func `a bare symbol holding a character hledger quotes for is no amount`(amount: String) {
        #expect { try Self.posting(amount) } throws: { error in
            guard let error = error as? LedgerError, error.line == 2,
                  case .invalidAmount = error.withoutLocation else { return false }
            return true
        }
    }
}
