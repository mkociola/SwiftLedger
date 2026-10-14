import Foundation
@testable import SwiftLedger
import Testing

/// The tests for the example's line endings, which no one section of the file
/// can show. Each section keeps its tests in a file of its own, so that changes
/// made side by side add to different files rather than all growing one past
/// the length SwiftLint allows.
extension ExampleJournalTests {
    /// The example is kept with Unix endings, since one file cannot show two,
    /// so its Windows twin is made here: the same text with every line ending
    /// replaced. It has to read as the same journal, teach the same style,
    /// and go back byte for byte in the endings it came with.
    @Test
    func `the example with windows endings reads the same and is written back byte-for-byte`() throws {
        let text = try Self.exampleText
        let twin = text.replacingOccurrences(of: "\n", with: "\r\n")
        let unix = try JournalParser().parse(text)
        let windows = try JournalParser().parse(twin)

        #expect(windows.transactions.map(\.sourceText) == unix.transactions.map(\.sourceText))
        #expect(windows.transactions.map(\.description) == unix.transactions.map(\.description))
        #expect(windows.transactions.map(\.postings) == unix.transactions.map(\.postings))
        #expect(windows.accountDirectives == unix.accountDirectives)
        #expect(windows.directives == unix.directives)

        #expect(windows.commodityFormats == unix.commodityFormats)
        #expect(windows.amountAlignment == unix.amountAlignment)
        #expect(windows.postingIndent == unix.postingIndent)
        #expect(unix.lineEnding == .unix)
        #expect(windows.lineEnding == .windows)

        #expect(JournalSerializer().serialize(windows) == twin)
    }
}
