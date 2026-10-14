import Foundation
@testable import SwiftLedger
import Testing

/// A `commodity`, `D` or `format` sample that shows no decimal mark, as the
/// directives above it read it, used to declare a digit count and leave the
/// marks as they were, where hledger 1.52.4 stops at the line and asks for a
/// decimal point or comma (issue #84). Each shape below is checked against
/// hledger.
@Suite("markless directive samples") struct MarklessSampleTests {
    /// One journal head and the line hledger stops at in it.
    struct Refused: CustomTestStringConvertible {
        let head: String
        let line: Int
        var testDescription: String {
            head
        }

        static let list = [
            Refused(head: "commodity €1000", line: 1),
            Refused(head: "commodity 1000 EUR", line: 1),
            Refused(head: "commodity €1000 ; house style", line: 1),
            Refused(head: "commodity $0", line: 1),
            Refused(head: "D 1000 EUR", line: 1),
            Refused(head: "D 1000", line: 1),
            Refused(head: "commodity $1,000,000", line: 1),
            Refused(head: "commodity €1.000,00\ncommodity €1000", line: 2),
            Refused(head: "commodity $1,000.00\ncommodity $1,000", line: 2),
            Refused(head: "decimal-mark ,\nD €1.000", line: 2),
            Refused(head: "decimal-mark .\ncommodity $1,000", line: 2),
            Refused(head: "commodity €\n  format €1000", line: 2),
            Refused(head: "commodity €\n  note euro\n  format €1000", line: 3),
        ]
    }

    @Test(arguments: Refused.list)
    func `a sample with no decimal mark refuses the file at its line`(refused: Refused) {
        let text = "\(refused.head)\n\n2024-01-01 Pay\n    Assets:Checking  €1.00\n    Income:Salary\n"
        #expect {
            try JournalParser().parse(text)
        } throws: { error in
            guard let error = error as? LedgerError, error.line == refused.line,
                  case .unreadableDirective = error.withoutLocation else { return false }
            return true
        }
    }

    /// Samples hledger reads: a lone mark with three digits after it is
    /// still a mark, and so is one with nothing behind it. A line indented
    /// under a `commodity` block that is not `format` is skipped there.
    @Test(arguments: [
        "commodity $1,000", "D 1,000 EUR", "commodity $1000.", "D 1000.", "commodity 1.000 EUR",
        "commodity €\n  format €1000.00", "commodity €\n  D 1000", "D 1.000,00 EUR\ncommodity $1,000",
    ])
    func `a sample that shows a mark still loads`(head: String) throws {
        let text = "\(head)\n\n2024-01-01 Pay\n    Assets:Checking  €1.00\n    Income:Salary\n"
        let journal = try JournalParser().parse(text)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    @Test
    func `the error names the directive and asks for a mark`() {
        #expect {
            try JournalParser().parse("decimal-mark ,\nD €1.000")
        } throws: { error in
            error.localizedDescription == "Line 2: Directive 'D €1.000' cannot be read: "
                + "its sample shows no decimal mark, as in 'D $1000.' or 'D €1.000,00'"
        }
    }
}
