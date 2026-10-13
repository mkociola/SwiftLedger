@testable import SwiftLedger
import Testing

/// `JournalSerializer` writes `account NAME  ; COMMENT` with both values
/// verbatim, and `JournalParser` reads the line back by position: the
/// comment opens at the first `;` with two spaces or tabs in front of it,
/// and the name and the comment are both trimmed. A value that looks like
/// that syntax used to build, be written, and come back from the next parse
/// as a different directive, with nothing thrown. Issue #71.
@Suite("account directive fields read back as syntax") struct AccountDirectiveSyntaxTests {
    /// A directive's fields, and the field path the error has to name when
    /// they are refused.
    struct Fields {
        var name: String
        var comment: String?
        var field = ""

        func directive() throws -> AccountDirective {
            try AccountDirective(name: name, comment: comment)
        }
    }

    /// One case per rule: the parser trims either end of the name and of the
    /// comment, two spaces or tabs and `;` open the comment, two spaces or
    /// tabs in a row end the name, and an empty name leaves no directive.
    static let refused = [
        Fields(name: " Assets:Checking", field: "name"),
        Fields(name: "Assets:Checking\t", field: "name"),
        Fields(name: "Assets:Checking  ; fake", field: "name"),
        Fields(name: "Assets:Checking\t\t; fake", field: "name"),
        Fields(name: "Assets  Checking", field: "name"),
        Fields(name: "Assets\t Checking", field: "name"),
        Fields(name: "", field: "name"),
        Fields(name: "Assets:Checking", comment: " note", field: "comment"),
        Fields(name: "Assets:Checking", comment: "note\t", field: "comment"),
    ]

    @Test(arguments: AccountDirectiveSyntaxTests.refused)
    func `a directive field the grammar would read as syntax is refused by name`(fields: Fields) {
        let error = #expect(throws: LedgerError.self) { try fields.directive() }
        guard case let .syntaxInField(field, _) = error else {
            Issue.record("expected syntaxInField, got \(String(describing: error))")
            return
        }
        #expect(field == fields.field)
    }

    /// A single tab inside a name is content, a `;` with one space in front
    /// of it is not a comment, and the comment runs to the end of the line
    /// whatever it holds, so each of these builds and comes back from a
    /// reload as the directive that was built.
    static let kept = [
        Fields(name: "Assets\tChecking\tSavings", comment: "note"),
        Fields(name: "Assets:Checking ;x"),
        Fields(name: "Assets:Checking", comment: "a ; inside  ; the comment"),
    ]

    @Test(arguments: AccountDirectiveSyntaxTests.kept)
    func `a directive the grammar reads back as itself still builds and round-trips`(fields: Fields) throws {
        let directive = try fields.directive()
        let text = JournalSerializer().serialize(Journal(items: [.accountDirective(directive)]))
        #expect(try JournalParser().parse(text).accountDirectives == [directive])
    }
}
