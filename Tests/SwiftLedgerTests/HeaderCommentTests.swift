import Foundation
@testable import SwiftLedger
import Testing

/// On a transaction line hledger ends the description at the first `;`,
/// whatever comes before it, and reads the rest of the line as the entry's
/// comment. The status and the code are read first, so a `;` inside the
/// parentheses of a code is part of the code. Issue #37.
@Suite("header comments") struct HeaderCommentTests {
    /// A header line and the fields hledger 1.52.4 reads out of it.
    struct Case: CustomTestStringConvertible {
        var line: String
        var status: ClearingStatus = .unmarked
        var code: String?
        var description: String
        var comment: String?

        var testDescription: String {
            line
        }
    }

    static let cases = [
        Case(line: "2024-01-01 Rent ; paid early", description: "Rent", comment: "paid early"),
        Case(line: "2024-01-01 Rent;paid early", description: "Rent", comment: "paid early"),
        Case(line: "2024-01-01 Rent\t; paid early", description: "Rent", comment: "paid early"),
        Case(line: "2024-01-01 Rent  ; paid ; early", description: "Rent", comment: "paid ; early"),
        Case(line: "2024-01-01 Rent | March ; tag:value", description: "Rent | March", comment: "tag:value"),
        Case(line: "2024-01-01 * ;paid early", status: .cleared, description: "", comment: "paid early"),
        Case(line: "2024-01-01 ;paid early", description: "", comment: "paid early"),
        Case(line: "2024-01-01 (CHQ);paid early", code: "CHQ", description: "", comment: "paid early"),
        Case(line: "2024-01-01 * (CHQ;1) Rent", status: .cleared, code: "CHQ;1", description: "Rent"),
        Case(line: "2024-01-01 (CHQ ; 1) Rent ; paid", code: "CHQ ; 1", description: "Rent", comment: "paid"),
    ]

    @Test(arguments: HeaderCommentTests.cases)
    func `the description ends at the first semicolon after the code`(header: Case) throws {
        let text = "\(header.line)\n    Expenses:Rent  $1.00\n    Assets:Checking\n"
        let journal = try JournalParser().parse(text)
        let entry = try #require(journal.transactions.first)

        #expect(entry.status == header.status)
        #expect(entry.code == header.code)
        #expect(entry.description == header.description)
        #expect(entry.comment == header.comment)
        #expect(JournalSerializer().serialize(journal) == text)
    }

    /// A rebuilt header writes the comment after two spaces, and the
    /// description ahead of it may hold no `;` of its own, or the reload
    /// would end the description there.
    @Test
    func `a description holding a semicolon is refused`() {
        #expect(throws: LedgerError.self) { try Self.entry(description: "Rent ; March") }
        #expect(throws: LedgerError.self) { try Self.entry(description: "Rent;March") }
    }

    /// With no code in front of it, a description opening with `(` is read
    /// as a code when a `)` follows anywhere on the line, the comment
    /// included, since the code is read before the comment.
    @Test
    func `a description opening a code the comment would close is refused`() {
        #expect(throws: LedgerError.self) { try Self.entry(description: "(note", comment: "paid)") }
    }

    /// A code is read before the comment, so a `;` inside it is content and
    /// the entry comes back as built.
    @Test(arguments: ["CHQ;1", "CHQ  ; 1"])
    func `a code holding a semicolon round-trips`(code: String) throws {
        let built = try Self.entry(code: code, description: "Rent", comment: "paid")
        let text = JournalSerializer().serialize(Journal(items: [.transaction(built)]))
        let read = try #require(JournalParser().parse(text).transactions.first)

        #expect(read.code == code)
        #expect(read.description == "Rent")
        #expect(read.comment == "paid")
    }

    private static func entry(code: String? = nil, description: String, comment: String? = nil) throws -> Transaction {
        try Transaction(
            date: JournalDate(year: 2024, month: 1, day: 1),
            code: code,
            description: description,
            postings: [
                Posting(accountName: "Expenses:Rent", amount: Amount(quantity: 1, commodity: "USD")),
                Posting(accountName: "Assets:Checking", amount: Amount(quantity: -1, commodity: "USD")),
            ],
            comment: comment,
        )
    }
}
