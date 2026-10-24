import Foundation

// MARK: - Dates a posting's comments write

extension Posting {
    /// A copy of this posting with `date` and `date2` read from its comments,
    /// the inline one first and then each line below it, with `year` for a
    /// date that leaves the year out.
    ///
    /// A date the comments do not write is kept as the posting has it. Only
    /// the parser sets one: an elided line split into a posting per commodity
    /// leaves its comments on one posting each, and dates the others the same.
    func datedByComments(year: Int) throws -> Posting {
        let written = try Self.writtenDates(in: commentLines, year: year)
        var copy = self
        (copy.date, copy.date2) = (written.date ?? date, written.date2 ?? date2)
        return copy
    }

    /// The `date:` and `date2:` tags for the dates this posting has and its
    /// comments do not write, or `nil` when they write all it has.
    ///
    /// `JournalSerializer` adds them to a rebuilt posting's inline comment,
    /// so that the next parse dates it the same. Only the legs of a split
    /// elided line need them, since only the parser dates a posting past
    /// what its comments say.
    func unwrittenDateTags(year: Int) -> String? {
        let written = (try? Self.writtenDates(in: commentLines, year: year)) ?? (date: nil, date2: nil)
        let tags = [
            written.date == nil ? date.map { "date:\($0)" } : nil,
            written.date2 == nil ? date2.map { "date2:\($0)" } : nil,
        ].compactMap(\.self)
        return tags.isEmpty ? nil : tags.joined(separator: ", ")
    }

    /// The inline comment, then each comment line below the posting without
    /// its indentation and marker.
    private var commentLines: [Substring] {
        (comment.map { [$0[...]] } ?? []) + trailingComments.map { $0.drop { $0 == " " || $0 == "\t" }.dropFirst() }
    }

    /// The first `date` and the first `date2` the comment lines write, in
    /// text order, the way hledger 1.52.4 reads a posting's comment.
    ///
    /// A tag is a name and a colon, the name being the last word before the
    /// colon, and its value runs to the next comma or the end of the line. So
    /// `date:2024-02-02` and `note, date:02-02` date a posting, while
    /// `other:1 date:2024-02-02` does not: that is `other`'s value. A
    /// `date:` or `date2:` value has to open with a date, after any spaces,
    /// and whatever follows the date is not read. A bracket anywhere in the
    /// text, made of digits, `-`, `/`, `.` and `=` with at least one digit
    /// and one separator, is ledger's form, `[date]`, `[=date2]` or
    /// `[date=date2]`, and has to be read whole. Anything else in brackets,
    /// `[note]` or `[2024]`, is text.
    ///
    /// The dates themselves are read the way a header's are, with `year` for
    /// a short one; a short secondary date in a bracket takes the year of the
    /// primary one beside it. A tag value or a bracket that should hold a date
    /// and does not makes hledger refuse the file, so it throws
    /// `LedgerError.invalidDate` here, where keeping it as text would date
    /// the posting differently from hledger without a word.
    static func writtenDates(in lines: [Substring], year: Int) throws -> (date: JournalDate?, date2: JournalDate?) {
        var found: [(name: Substring, date: JournalDate)] = []
        for line in lines {
            var rest = line
            while let colon = rest.firstIndex(of: ":") {
                let before = rest[..<colon]
                try found += bracketedDates(in: before, year: year)
                let name = before.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).last ?? ""
                rest = rest[rest.index(after: colon)...]
                // A colon with no name before it is text, and the next tag
                // may start straight after it.
                guard !name.isEmpty else { continue }
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                let value = rest[..<end]
                if name == "date" || name == "date2" {
                    var text = value.drop { $0 == " " || $0 == "\t" }
                    try found.append((name, readDate(&text, year: year, written: value)))
                }
                try found += bracketedDates(in: value, year: year)
                rest = rest[end...].dropFirst()
            }
            try found += bracketedDates(in: rest, year: year)
        }
        return (found.first { $0.name == "date" }?.date, found.first { $0.name == "date2" }?.date)
    }

    /// The dates the `[date=date2]` brackets in `text` write, in order.
    private static func bracketedDates(in text: Substring, year: Int) throws -> [(name: Substring, date: JournalDate)] {
        var dates: [(name: Substring, date: JournalDate)] = []
        var rest = text
        while let open = rest.firstIndex(of: "[") {
            rest = rest[rest.index(after: open)...]
            var inner = rest.prefix { $0.isASCII && ($0.isNumber || "-/.=".contains($0)) }
            guard rest.dropFirst(inner.count).first == "]",
                  inner.contains(where: \.isNumber), inner.contains(where: { "-/.".contains($0) })
            else { continue }
            rest = rest.dropFirst(inner.count + 1)
            let written = inner
            let first = inner.first == "=" ? nil : try readDate(&inner, year: year, written: written)
            if let first { dates.append(("date", first)) }
            if inner.first == "=" {
                inner = inner.dropFirst()
                try dates.append(("date2", readDate(&inner, year: first?.year ?? year, written: written)))
            }
            guard inner.isEmpty else { throw LedgerError.invalidDate(String(written)) }
        }
        return dates
    }

    /// Reads a date off the front of `text`, refusing it as `written`.
    private static func readDate(_ text: inout Substring, year: Int, written: Substring) throws -> JournalDate {
        do {
            // The line number is the header reader's; a posting's date is
            // refused by what it says instead, and the parser adds the line.
            return try JournalParser.consumeDate(&text, year: year, lineNumber: 0)
        } catch {
            throw LedgerError.invalidDate(String(written))
        }
    }
}
