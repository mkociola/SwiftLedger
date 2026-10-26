// MARK: - Reading a transaction's header line

import Foundation

extension JournalParser {
    /// Reads the line an entry starts on: its dates, status, code, description
    /// and inline comment, by the rules the type's documentation states.
    func parseHeader(
        _ line: String,
        year: Int?,
        lineNumber: Int,
    ) throws -> ParsedHeader {
        // DATE [= AUXDATE]
        var afterDates = line[...]
        let (date, auxDate) = try consumeDates(&afterDates, year: year, lineNumber: lineNumber)
        var rest = afterDates.trimmingCharacters(in: .whitespaces)

        // Optional status (* or !)
        var txStatus: ClearingStatus = .unmarked
        if rest.hasPrefix("*") {
            txStatus = .cleared
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("!") {
            txStatus = .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Optional (CODE). A `(` here opens a code, and one with no `)`
        // after it on the line refuses the line, as hledger refuses it: a
        // missing `)` is a typo, and kept, the whole of it became the payee
        // without a word (issue #101).
        var code: String?
        if rest.hasPrefix("(") {
            guard let closeIdx = rest.firstIndex(of: ")") else {
                throw LedgerError.parseError(line: lineNumber, message: "Expected ')' to close the transaction code")
            }
            code = String(rest[rest.index(after: rest.startIndex) ..< closeIdx])
            rest = String(rest[rest.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        }

        // The description runs to the first `;`, however few spaces precede
        // it, as hledger reads it. The code is read first, so a `;` inside
        // its parentheses stays in the code.
        var comment: String?
        if let semicolon = rest.firstIndex(of: ";") {
            comment = rest[rest.index(after: semicolon)...].trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<semicolon])
        }

        let description = rest.trimmingCharacters(in: .whitespaces)
        return ParsedHeader(
            date: date,
            auxDate: auxDate,
            status: txStatus,
            code: code,
            description: description,
            comment: comment,
        )
    }
}
