// MARK: - Reading a journal's own layout and declared display styles

import Foundation

extension JournalParser {
    /// Splits `text` into its lines, with the line ending taken off each, and
    /// says which ending the file uses.
    ///
    /// A line ends at `\n`, and the `\r` a Windows ending puts in front of
    /// that is the other half of the ending rather than the last character of
    /// the line. Taken off here, before anything reads a line, it reaches no
    /// field, no directive and no `sourceText`, so a journal kept on Windows
    /// is read as the same journal kept anywhere else: a blank line is blank,
    /// an account is declared under the name every posting uses, and a bare
    /// `comment` opens a block.
    ///
    /// Only the last scalar of a line, and only once. A `\r` anywhere else is
    /// not a line ending, and is left for the field it lands in to refuse by
    /// name. That is also what becomes of a file with classic Mac endings,
    /// which holds no `\n` and so is one line.
    ///
    /// The ending is the one most lines use. A file that mixes the two is
    /// written back in that one throughout, which is what an editor does with
    /// such a file, and an even split reads as Unix, the ending a journal
    /// that came from no file is written with. What follows the last `\n` is
    /// not a line anything ended, so it has no say: a `\r` there comes off, as
    /// it does in hledger, and is not counted.
    static func lines(of text: String) -> (lines: [String], ending: LineEnding) {
        var lines = text.components(separatedBy: "\n")
        let ended = lines.count - 1
        var endedTheWindowsWay = 0
        for index in lines.indices where lines[index].unicodeScalars.last == "\r" {
            lines[index].unicodeScalars.removeLast()
            if index < ended { endedTheWindowsWay += 1 }
        }
        return (lines, endedTheWindowsWay * 2 > ended ? .windows : .unix)
    }

    /// Reads what a `D`, `commodity` or `decimal-mark` directive states, if
    /// the line is one: the display style a sample amount shows, and the
    /// decimal mark every lone mark below the line is read against
    /// (`JournalStyleCollector.declaredDecimalMark(for:)`).
    ///
    /// ledger and hledger both spell a style as a sample amount, in three
    /// places: `D $1,000.00`, the one-line `commodity $1,000.00`, and the
    /// indented `format $1,000.00` inside a `commodity` block. An indented line
    /// is handed here only from such a block: `declare(at:in:into:year:)`
    /// reads the block above the line and passes over a `format` line under
    /// any other, as hledger skips it. The serializer reads the directives
    /// through that function too, so that it writes a rebuilt amount by the
    /// mark the next parse reads it by. The sample is itself read under whatever the file has declared
    /// above it, as hledger reads it, so `commodity €1.000` below
    /// `decimal-mark ,` states a grouped whole number. hledger's
    /// `decimal-mark .` or `decimal-mark ,` states no style and names no
    /// commodity; it says how every amount below it is read.
    ///
    /// A line hledger refuses to read is refused here too, with
    /// `LedgerError.unreadableDirective`: a `decimal-mark` that names neither
    /// mark, a `D` with no number in its sample, a `D` or `commodity` with
    /// nothing after it, a `commodity` with more than a symbol or a sample
    /// amount on it, a `format` with no sample amount, a sample that shows no
    /// decimal mark as the lines above it read it. Kept, such a line declared
    /// no mark, and the amounts below it were read by another mark than the
    /// author wrote it for, without a word. Text after a `D` sample is read
    /// past, as hledger reads past it, and the line is kept as it came.
    func declareFormat(from line: String, into style: inout JournalStyleCollector) throws {
        let isIndented = line.first == " " || line.first == "\t"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The keyword ends at a space or a tab, as it does in hledger, where
        // `decimal-mark\t,` declares the comma as much as `decimal-mark ,`
        // does. Matched on the space alone, a tab dropped the whole line
        // without a word, and from this version that silence changes what the
        // amounts below it are worth. A keyword alone on its line is the
        // directive with nothing after it, which is refused below.
        let keyword = ["D", "commodity", "format", "decimal-mark"].first {
            trimmed.hasPrefix($0) && trimmed.dropFirst($0.count).first?.isWhitespace != false
        }
        // Only a line at the margin is refused. An indented one is a
        // subdirective of the block above it, and hledger skips one it does
        // not know under a `commodity` or an `account` block, so nothing but
        // a `format` line is read from it, and that is refused for nothing
        // but a sample with no decimal mark, which hledger does read.
        let refuses = !isIndented
        // hledger reads every line opening with `D` as a `D` directive, so
        // `Decimal-Mark ,` is a `D` with no gap after it, and hledger stops
        // there. Kept as a directive nobody reads, it declared no comma.
        if keyword == nil, refuses, trimmed.first == "D" { throw Self.unreadableDefault(trimmed) }
        guard let keyword else { return }
        // Indented, only `format` declares anything. An indented `D`,
        // `commodity` or `decimal-mark` line is a subdirective hledger skips,
        // and read here it declared a mark, or a default commodity, for every
        // amount below the block that hledger reads by another (issue #105).
        // At the margin, `format` is nothing hledger reads.
        guard isIndented == (keyword == "format") else { return }
        let argument = trimmed.dropFirst(keyword.count)

        if keyword == "decimal-mark" {
            // hledger reads the first character past the gap and nothing
            // after it, so `decimal-mark , as at the bank` declares the comma
            // and `decimal-mark ; comma` declares nothing and is refused.
            let mark = argument.first { !$0.isWhitespace }
            if let mark, mark == "." || mark == "," {
                style.declareDecimalMark(mark)
            } else if refuses {
                throw LedgerError.unreadableDirective(trimmed, reason: "the mark must be '.' or ','")
            }
            return
        }

        // A directive may carry a comment of its own, and `D $1,000.00 ; house
        // style` states a style all the same, so the sample is what precedes
        // the `;`. Handing the comment to the amount parser loses the whole
        // declaration, silently, since a directive that does not parse is left
        // alone by design.
        //
        // A `\r` left behind the sample is taken off it as well. The line
        // ending is gone by now, so this one is a stray, in a file converted
        // twice and ending its lines `\r\r\n`. The line is kept with it, but
        // a declaration lost to it would change what the amounts below are
        // worth without a word, where hledger reads straight past it.
        let (field, _) = splitPostingComment(String(argument))
        let sample = field?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let parsed = try? parseShapedAmount(sample, lineNumber: 0, in: style) else {
            try Self.refuseUnreadableSample(keyword, sample: sample, directive: trimmed, refuses: refuses)
            return
        }
        // hledger asks every sample for a decimal mark, as the directives
        // above it read the sample, and stops at one with none: `€1000`, or
        // `€1.000` under `decimal-mark ,`. Indented, only `format` is asked,
        // as the one line a `commodity` block reads.
        let shape = parsed.shape
        if shape.decimalMark == nil, refuses || keyword == "format" {
            let example = "as in '\(keyword) $1000.' or '\(keyword) €1.000,00'"
            throw LedgerError.unreadableDirective(trimmed, reason: "its sample shows no decimal mark, \(example)")
        }
        style.declare(shape, as: parsed.amount, isDefault: keyword == "D")
    }

    /// Refuses a `D`, `commodity` or `format` line whose sample is no amount,
    /// where hledger refuses it. `commodity` may name a symbol and nothing
    /// else, bare or in quotes (`commodity $`, `commodity "AAPL 2"`), which
    /// states no style. Anything else on a `commodity` or a `format` line is
    /// one hledger stops at, and kept, the style it meant to state was lost
    /// without a word: `commodity xyz abc`, `commodity $1,000.00 x`, `format
    /// xyz` (issue #106), and a `commodity` with nothing after it. A `D` is
    /// refused with no number in its sample; with one, hledger reads past
    /// whatever follows the sample, and the line is kept. An indented line,
    /// `refuses` false, is refused only as a `format` line.
    private static func refuseUnreadableSample(
        _ keyword: String, sample: String, directive: String, refuses: Bool,
    ) throws {
        if keyword == "commodity", namesSymbolAlone(sample) { return }
        if keyword == "D", sample.contains(where: \.isNumber) { return }
        if refuses || keyword == "format" { throw unreadable(keyword, sample: sample, directive: directive) }
    }

    /// Whether `sample` is a commodity symbol and nothing else: one bare word,
    /// or one quoted symbol with nothing after its closing quote, which is
    /// the `commodity` line's one form besides a sample amount.
    private static func namesSymbolAlone(_ sample: String) -> Bool {
        guard sample.hasPrefix("\"") else { return !sample.isEmpty && !sample.contains(where: \.isWhitespace) }
        let inner = sample.dropFirst()
        return inner.last == "\"" && !inner.dropLast().contains("\"")
    }

    /// Why hledger refuses a `D`, `commodity` or `format` line whose sample is
    /// no amount. `commodity $` names a commodity, a form a `D` does not have,
    /// so a `commodity` is refused with nothing after it or with more than a
    /// symbol; `format` takes nothing but a sample amount.
    private static func unreadable(_ keyword: String, sample: String, directive: String) -> LedgerError {
        switch keyword {
        case "D": unreadableDefault(directive)
        case "format":
            .unreadableDirective(directive, reason: "'format' takes a sample amount, such as 'format $1,000.00'")
        default: .unreadableDirective(
                directive,
                reason: sample.isEmpty
                    ? "it names no commodity and no sample amount"
                    : "it names neither a sample amount nor a commodity symbol alone, "
                    + "as 'commodity $1,000.00' or 'commodity $' do",
            )
        }
    }

    /// The error for a `D` line with no sample amount after the `D`.
    private static func unreadableDefault(_ directive: String) -> LedgerError {
        .unreadableDirective(directive, reason: "'D' takes a sample amount, such as 'D $1,000.00'")
    }

    /// The column `line`'s amount field starts at: past the account token,
    /// past the run of two or more spaces that ends it.
    ///
    /// `accountToken` must be the account exactly as the line writes it,
    /// delimiters included: searching for the bare name of `(Reserve:capital)`
    /// lands inside the parentheses, where the next character is `)` rather
    /// than the gap, and this would answer `nil` for every virtual posting —
    /// an envelope journal would teach the collector nothing and its margin
    /// would silently become the library default.
    ///
    /// Measured on the original line, indentation included, because that is
    /// what a column is. Characters, not display width — a tab counts once,
    /// which is what the serializer will write against anyway.
    static func amountColumn(in line: String, after accountToken: String) -> Int? {
        guard !accountToken.isEmpty, let account = line.range(of: accountToken) else { return nil }
        var index = account.upperBound
        var spaces = 0
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            spaces += 1
            index = line.index(after: index)
        }
        guard spaces >= 2, index < line.endIndex else { return nil }
        return line.distance(from: line.startIndex, to: index)
    }
}
