// MARK: - Reading a journal's own layout and declared display styles

import Foundation

extension JournalParser {
    /// Reads what a `D`, `commodity` or `decimal-mark` directive states, if
    /// the line is one: the display style a sample amount shows, and the
    /// decimal mark every lone mark below the line is read against
    /// (`JournalStyleCollector.declaredDecimalMark(for:)`).
    ///
    /// ledger and hledger both spell a style as a sample amount, in three
    /// places: `D $1,000.00`, the one-line `commodity $1,000.00`, and the
    /// indented `format $1,000.00` inside a `commodity` block. An indented line
    /// can only reach here from such a block — the ones inside a transaction
    /// are consumed with it — so no block tracking is needed to tell them
    /// apart. The sample is itself read under whatever the file has declared
    /// above it, as hledger reads it, so `commodity €1.000` below
    /// `decimal-mark ,` states a grouped whole number. hledger's
    /// `decimal-mark .` or `decimal-mark ,` states no style and names no
    /// commodity; it says how every amount below it is read.
    ///
    /// Anything that does not parse as an amount, or as one of the two marks,
    /// is left alone. A directive SwiftLedger misreads here costs nothing but
    /// the guess: the line itself is still written back verbatim.
    func declareFormat(from line: String, into style: inout JournalStyleCollector) {
        let isIndented = line.first == " " || line.first == "\t"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The keyword ends at a space or a tab, as it does in hledger, where
        // `decimal-mark\t,` declares the comma as much as `decimal-mark ,`
        // does. Matched on the space alone, a tab dropped the whole line
        // without a word, and from this version that silence changes what the
        // amounts below it are worth.
        let keyword = ["D", "commodity", "format", "decimal-mark"].first {
            trimmed.hasPrefix($0) && trimmed.dropFirst($0.count).first?.isWhitespace == true
        }
        guard let keyword else { return }
        guard keyword != "format" || isIndented else { return }

        // A directive may carry a comment of its own, and `D $1,000.00 ; house
        // style` states a style all the same, so the sample is what precedes
        // the `;`. Handing the comment to the amount parser loses the whole
        // declaration, silently, since a directive that does not parse is left
        // alone by design.
        let (sample, _) = splitPostingComment(String(trimmed.dropFirst(keyword.count)))
        guard let sample else { return }
        if keyword == "decimal-mark" {
            if sample == "." || sample == ",", let mark = sample.first { style.declareDecimalMark(mark) }
            return
        }
        // `commodity $` names a commodity without stating a style; only the
        // sample-amount forms say anything to record.
        guard sample.contains(where: \.isNumber),
              let parsed = try? parseShapedAmount(sample, lineNumber: 0, in: style) else { return }
        style.declare(parsed.shape, commodity: parsed.amount.commodity, isDefault: keyword == "D")
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
