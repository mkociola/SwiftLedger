import Foundation
@testable import SwiftLedger
import Testing

/// A `decimal-mark`, `D` or `commodity` line the parser recognises but cannot
/// read used to be kept verbatim and declare nothing, so a typo in it loaded
/// the file with other figures than the author meant, where hledger stops at
/// the line (issue #78). Each shape below is one hledger 1.52.4 refuses, and
/// each is refused here with the line it stands on.
@Suite("malformed directives") struct MalformedDirectiveTests {
    @Test(arguments: [
        "decimal-mark x", "decimal-mark", "decimal-mark ", "decimal-mark\t", "decimal-mark ; comma",
        "Decimal-Mark ,", "DECIMAL-MARK ,", "Dx", "D", "D ", "D xyz", "D $", "D\t$", "D xyz ; house style",
        "D ; house style", "commodity", "commodity ", "commodity ; euro", "decimal-mark x\r", "D xyz\r",
    ])
    func `a directive hledger cannot read refuses the file at its line`(directive: String) {
        let text = "; header\n\(directive)\n\n2024-01-01 Pay\n    Assets:Checking  €1.000\n    Income:Salary\n"
        #expect {
            try JournalParser().parse(text)
        } throws: { error in
            guard let error = error as? LedgerError, error.line == 2,
                  case .unreadableDirective = error.withoutLocation else { return false }
            return true
        }
    }

    /// hledger reads the first character after `decimal-mark` and nothing
    /// past it, so trailing text or a second mark still declares the first.
    @Test(arguments: ["decimal-mark , trailing", "decimal-mark ,,", "decimal-mark\t,\tx", "decimal-mark ,;c"])
    func `decimal-mark reads its first character and ignores the rest`(directive: String) throws {
        let text = "\(directive)\n\n2024-01-01 Pay\n    Assets:Checking  €1.000\n    Income:Salary\n"
        let journal = try JournalParser().parse(text)
        #expect(journal.transactions.first?.postings.first?.amount.quantity == 1000)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// Lines hledger loads stay loadable: a `commodity` line naming a symbol
    /// declares no style, and an indented line under a `commodity` block is a
    /// subdirective hledger skips.
    @Test(arguments: [
        "commodity xyz", "commodity $", "commodity \"a b\"", "commodity xyz ; c",
        "decimal-mark .x", "commodity €\n  D xyz", "commodity €\n  decimal-mark x",
    ])
    func `a directive hledger loads still loads`(directive: String) throws {
        let text = "\(directive)\n\n2024-01-01 Pay\n    Assets:Checking  €1.00\n    Income:Salary\n"
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `the error names the directive and why it cannot be read`() {
        let error = LedgerError.inJournal(
            line: 3, entry: nil,
            underlying: .unreadableDirective("decimal-mark x", reason: "the mark must be '.' or ','"),
        )
        #expect(error.localizedDescription
            == "Line 3: Directive 'decimal-mark x' cannot be read: the mark must be '.' or ','")
    }
}
