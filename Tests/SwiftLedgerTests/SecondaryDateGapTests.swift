import Foundation
@testable import SwiftLedger
import Testing

/// A secondary date follows an `=` that follows the primary date directly,
/// and follows the `=` directly; hledger reads nothing else as one. The
/// parser used to skip spaces and tabs on both sides of the `=`, so
/// `2024-01-08 = 01-10 Rent` carried a secondary date hledger never gives
/// it, and `2024-01-08= 01-10 Rent` loaded where hledger refuses it at the
/// space (issue #119). Pinned against hledger 1.52.4 in
/// `secondary-date-gap-before` and `secondary-date-gap-after`.
@Suite("whitespace around a secondary date's equals sign") struct SecondaryDateGapTests {
    /// An `=` after a gap is the first character of the description, a
    /// status in front of it or not.
    @Test(arguments: [
        ("2024-01-08 = 01-10 Rent", "= 01-10 Rent"), ("2024-01-08 =01-10 Rent", "=01-10 Rent"),
        ("2024-01-08\t= 01-10 Rent", "= 01-10 Rent"), ("2024-01-08 * = 01-10 Rent", "= 01-10 Rent"),
    ])
    func `an equals sign after a gap opens the description, not a secondary date`(
        header: String, description: String,
    ) throws {
        let text = "\(header)\n    Expenses:Rent    $4.00\n    Assets:Checking\n"
        let entry = try #require(JournalParser().parse(text).transactions.first)
        #expect(entry.auxDate == nil)
        #expect(entry.description == description)
    }

    /// A gap after the `=` leaves no date where one has to be, and the file
    /// is refused at the line.
    @Test(arguments: ["2024-01-08= 01-10 Rent", "2024-01-08=\t01-10 Rent", "2024-01-08= Rent"])
    func `a gap after the equals sign refuses the file`(header: String) {
        let text = "\(header)\n    Expenses:Rent    $4.00\n    Assets:Checking\n"
        #expect { try JournalParser().parse(text) } throws: { ($0 as? LedgerError)?.line == 1 }
    }
}
