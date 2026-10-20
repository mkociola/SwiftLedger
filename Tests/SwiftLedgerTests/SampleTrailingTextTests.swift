import Foundation
@testable import SwiftLedger
import Testing

/// A `commodity` line holds a sample amount, or a symbol and nothing else,
/// and a `format` line under a `commodity` block holds a sample amount.
/// hledger refuses anything more, where the parser kept the line and dropped
/// the style it meant to state without a word (issue #106). Under every
/// other block hledger skips an indented line, `format` included, and so
/// does the parser now, where it used to read a `format` line under an
/// `account` block as that account's commodity style (issue #111). A symbol
/// alone is held to the rule for a bare symbol in an amount, so `commodity
/// E-R` is refused as hledger refuses it, where the parser loaded it and
/// declared nothing, and `commodity "E-R"` loads. Each shape is hledger
/// 1.52.4's reading, pinned in `commodity-sample-trailing-text`,
/// `commodity-symbol-trailing-text`, the `commodity-bare-symbol-*` journals,
/// `format-no-amount`, `format-under-account` and `commodity-symbol-forms`.
@Suite("sample lines hledger cannot read") struct SampleTrailingTextTests {
    /// Each is refused at the line it stands on, a `format` line with other
    /// subdirectives above it included, and a symbol alone holding a
    /// character hledger quotes for.
    @Test(arguments: [
        "commodity xyz abc", "commodity $1,000.00 x", "commodity € x", "commodity \"AAPL 2\" x",
        "commodity xyz\tabc", "commodity €\n  format xyz", "commodity €\n  format $1,000.00 x",
        "commodity €\n  format", "commodity €\n  note euro\n  format",
        "commodity E-R", "commodity E*R", "commodity E{R", "commodity E.R", "commodity E1R",
        "commodity €\ncommodity E=R",
    ])
    func `a commodity or format line with text hledger cannot read refuses the file`(head: String) {
        let text = "\(head)\n\n2024-01-01 Pay\n    Assets:Checking  €1.00\n    Income:Salary\n"
        let line = head.components(separatedBy: "\n").count
        #expect { try JournalParser().parse(text) } throws: { error in
            guard let error = error as? LedgerError, error.line == line,
                  case .unreadableDirective = error.withoutLocation else { return false }
            return true
        }
    }

    /// Each is a line hledger reads: a symbol alone, bare or in quotes, a
    /// sample with a comment after it, a `D` with text after its sample, a
    /// `format` line under a block that is no `commodity` block, and a
    /// periodic entry's posting to an account named `format`. Every one goes
    /// back as it came.
    @Test(arguments: [
        "commodity \"AAPL 2\"", "commodity \"E-R\"", "commodity m²", "commodity E(R)", "commodity xyz ; note",
        "commodity $1,000.00  ; note", "commodity USD 1,000.00", "D $1,000.00 x", "account Foo\n  format xyz",
        "account Foo\n  format €1000", "payee Foo\n  format", "commodity €\n  note x\n  format €1.000,00",
        "~ monthly\n    format  €1000",
    ])
    func `a line hledger reads still loads and goes back as it came`(head: String) throws {
        let text = "\(head)\n\n2024-01-01 Pay\n    Assets:Checking  €1.00\n    Income:Salary\n"
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// The journal from issue #111: a `format` line declares the style under
    /// a `commodity` block, other subdirectives between them or not, and
    /// under an `account` or `payee` block it declares nothing, so `€1.500`
    /// below is fifteen hundred under the first and one and a half under the
    /// others, as hledger reads them.
    static let blocks: [(String, Decimal)] = [
        ("commodity €", 1500), ("account Assets:Checking", 1.5), ("payee Foo", 1.5),
    ]

    @Test(arguments: SampleTrailingTextTests.blocks)
    func `a format line declares a style under a commodity block only`(block: String, quantity: Decimal) throws {
        let text = "\(block)\n  note x\n  format €1.000,00\n\n"
            + "2024-01-01 Salary\n    Assets:Checking  €1.500\n    Income:Salary\n"
        #expect(try DecimalMarkDirectiveTests.quantities(in: text) == [quantity, -quantity])
    }
}
