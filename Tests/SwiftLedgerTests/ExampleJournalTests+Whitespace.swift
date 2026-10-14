@testable import SwiftLedger
import Testing

/// The tests for the example's line of nothing but spaces. Each section keeps
/// its tests in a file of its own, so that changes made side by side add to
/// different files rather than all growing one past the length SwiftLint
/// allows.
extension ExampleJournalTests {
    /// The line under the car wash holds four spaces. It ended the entry, and
    /// it is the next item with its spaces on it, which is what lets the file
    /// go back byte for byte.
    @Test
    func `the example keeps a whitespace-only line as it came`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let index = try #require(journal.items.firstIndex { item in
            if case let .transaction(entry) = item { return entry.description == "Car wash" }
            return false
        })
        #expect(journal.transactions.first { $0.description == "Car wash" }?.postings.count == 2)
        #expect(journal.items[index + 1] == .directive("    "))
    }
}
