@testable import SwiftLedger
import Testing

/// Kept in a file of its own: `ExampleJournalTests.swift` is at the length
/// SwiftLint allows a file, so a new example test goes beside it rather than
/// into it.
extension ExampleJournalTests {
    /// The slash date, the dotted date and the secondary date without a year
    /// are all entries, and each is dated as hledger dates it. Read the way
    /// the parser once read them, the first two were directives and the third
    /// refused the file.
    @Test
    func `the example's dates written other ways are read as hledger reads them`() throws {
        let journal = try JournalParser().parse(Self.exampleText)
        let dates = ["Taxi from the station", "Bus ticket", "Train ticket, charged the next day"].map { payee in
            journal.transactions.first { $0.description == payee }.map { [$0.date, $0.auxDate] }
        }
        #expect(try dates == [
            [JournalDate(year: 2024, month: 3, day: 4), nil],
            [JournalDate(year: 2024, month: 3, day: 6), nil],
            [JournalDate(year: 2024, month: 3, day: 7), JournalDate(year: 2024, month: 3, day: 8)],
        ])
    }
}
