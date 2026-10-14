// MARK: - Dates

extension JournalParser {
    /// Whether a line outside a transaction opens one.
    ///
    /// hledger reads every line that opens with a digit as an entry, and
    /// refuses the file when the date it then reads is no date. Waiting for a
    /// date of one fixed shape instead kept `2024/1/5 Rent` as a directive,
    /// and the postings under it with it, so the entry fell out of every
    /// balance without a word (issue #36). Opening on the digit sends a date
    /// that cannot be read to `consumeDates`, which says so.
    func startsWithDate(_ str: String) -> Bool {
        str.first.map(Self.isDigit) ?? false
    }

    /// Reads the dates a transaction header opens with, the secondary one
    /// after an `=` included, and leaves `rest` at what follows them.
    ///
    /// A date is written as hledger writes one: year, month and day with the
    /// same `-`, `/` or `.` between them, `2024-01-05`, `2024/1/5` or
    /// `2024.01.05`, or month and day alone, `1/5`. The year a short date
    /// leaves out is the one the last `Y` or `year` line set, `year`, or the
    /// current year when no line has, which is hledger's reading; a short
    /// secondary date takes the primary date's year instead. A rebuilt entry
    /// is still written `YYYY-MM-DD`, and an untouched one keeps its own
    /// spelling in `sourceText`.
    ///
    /// The dates have to end where the header's next field can begin, at a
    /// space, a tab or the end of the line, so `2024-01-08x` is refused
    /// rather than read as a date and a description of `x`, as hledger
    /// refuses it.
    func consumeDates(_ rest: inout Substring, year: Int?, lineNumber: Int) throws -> (JournalDate, JournalDate?) {
        let date = try consumeDate(&rest, year: year, lineNumber: lineNumber)
        var auxDate: JournalDate?
        let afterGap = rest.drop { $0 == " " || $0 == "\t" }
        if afterGap.first == "=" {
            rest = afterGap.dropFirst().drop { $0 == " " || $0 == "\t" }
            auxDate = try consumeDate(&rest, year: date.year, lineNumber: lineNumber)
        }
        guard rest.first.map({ $0 == " " || $0 == "\t" }) ?? true else {
            throw LedgerError.parseError(line: lineNumber, message: "Expected a space after the date, got '\(rest)'")
        }
        return (date, auxDate)
    }

    /// Reads one date off the front of `text`, leaving `text` past it.
    private func consumeDate(_ text: inout Substring, year: Int?, lineNumber: Int) throws -> JournalDate {
        let start = text
        var parts: [Substring] = []
        var separators: Set<Character> = []
        while true {
            let digits = text.prefix(while: Self.isDigit)
            text = text.dropFirst(digits.count)
            parts.append(digits)
            // A separator belongs to the date only with a digit after it, and
            // a date has three parts at most, so `2024-01-08-` ends the date
            // at the last `-` and leaves it to be refused as what follows.
            guard parts.count < 3, let mark = text.first, "-/.".contains(mark),
                  text.dropFirst().first.map(Self.isDigit) == true
            else { break }
            separators.insert(mark)
            text = text.dropFirst()
        }
        let written = String(start[..<text.startIndex])
        guard parts.count > 1 else {
            throw LedgerError.parseError(line: lineNumber, message: "Expected date, got '\(start)'")
        }
        // A full date's year has four digits or more, and every separator in
        // it is the same one, or hledger refuses it.
        let numbers = parts.compactMap { Int($0) }
        guard separators.count == 1, numbers.count == parts.count, parts.count == 2 || parts[0].count >= 4 else {
            throw LedgerError.invalidDate(written)
        }
        let full = parts.count == 3 ? numbers : [year ?? JournalDate.today.year] + numbers
        return try JournalDate(year: full[0], month: full[1], day: full[2])
    }

    /// Reads what a directive line declares for the lines below it: the
    /// display style and decimal mark a `D`, `commodity` or `decimal-mark`
    /// line states, and the year a `Y` or `year` line sets.
    func declare(from line: String, into style: inout JournalStyleCollector, year: inout Int?) throws {
        try declareFormat(from: line, into: &style)
        year = try yearDirective(line) ?? year
    }

    /// Reads the year a `Y` or `year` line sets for the short dates below
    /// it, or returns `nil` when the line is neither.
    ///
    /// hledger takes every line at the margin that opens with `Y`, and every
    /// one opening with `year`, for this directive, the space before the year
    /// optional, and refuses one it cannot read four digits or more of a year
    /// from, or that carries anything past the year but a comment. So does
    /// this, at the line, with `LedgerError.unreadableDirective`: kept as a
    /// directive nobody reads, `Y 24` would leave every short date below it
    /// in the wrong year. The line itself is kept verbatim like any other.
    private func yearDirective(_ line: String) throws -> Int? {
        guard let keyword = ["year", "Y"].first(where: line.hasPrefix) else { return nil }
        var rest = line.dropFirst(keyword.count).drop { $0 == " " || $0 == "\t" }
        let digits = rest.prefix(while: Self.isDigit)
        rest = rest.dropFirst(digits.count).drop { $0 == " " || $0 == "\t" }
        guard digits.count >= 4, let year = Int(digits), rest.isEmpty || rest.first == ";" || rest.first == "#"
        else {
            throw LedgerError.unreadableDirective(line, reason: "it takes a year of four digits or more")
        }
        return year
    }

    /// ASCII digits only: hledger reads no other digit in a date.
    private static func isDigit(_ char: Character) -> Bool {
        char.isASCII && char.isNumber
    }
}
