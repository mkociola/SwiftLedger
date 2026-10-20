import Foundation
@testable import SwiftLedger
import Testing

/// The indented lines under an `account` directive are its subdirectives,
/// kept as `.directive` items of their own, and removing the directive used
/// to leave them where they stood: under the previous directive, where
/// hledger and the parser refuse the file, or under an entry's postings,
/// where the next parse booked them as a posting (issue #117). Removing the
/// directive takes them with it now, by name or by value, and a blank line
/// ends what goes.
@Suite("removing an account directive with subdirectives") struct AccountSubdirectiveRemovalTests {
    static let text = "account Assets:Checking\n    note current account\n\n"
        + "account Assets:Savings\n    note savings\n    ; for the statement\n    \n    type Asset\n\n"
        + "2024-01-01 Salary\n    Assets:Checking  $1.00\n    Income:Salary\n"

    /// What the file holds once the savings declaration is gone: its `note`,
    /// the comment, the line of nothing but spaces and its `type` with it, the checking
    /// declaration's own note and the entry untouched, and a file the parser
    /// loads again.
    static let without = "account Assets:Checking\n    note current account\n\n\n"
        + "2024-01-01 Salary\n    Assets:Checking  $1.00\n    Income:Salary\n"

    @Test
    func `removing by name takes the subdirectives with it`() throws {
        var journal = try JournalParser().parse(Self.text)
        let removed = journal.removeAccountDirective(named: "Assets:Savings")
        #expect(removed?.name == "Assets:Savings")
        let written = JournalSerializer().serialize(journal)
        #expect(written == Self.without)
        #expect(try JournalParser().parse(written).transactions.count == 1)
    }

    @Test
    func `removing by value takes the subdirectives with it`() throws {
        var journal = try JournalParser().parse(Self.text)
        let removed = try journal.remove(.accountDirective(AccountDirective(name: "Assets:Savings")))
        #expect(removed)
        #expect(JournalSerializer().serialize(journal) == Self.without)
    }
}
