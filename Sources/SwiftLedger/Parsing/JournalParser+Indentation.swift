// MARK: - Reading the lines at the top level that no other branch reads

import Foundation

extension JournalParser {
    /// Reads the line at `index`, which no earlier branch of `parse` read, for
    /// what it declares, and refuses one hledger refuses.
    ///
    /// At the margin the line is a directive. It is read for the style, mark
    /// or year it states (`declare(from:into:year:)`), which refuses what
    /// hledger cannot read, and then refused if it opens with no word hledger
    /// reads at all (`requireKnownDirective`), in that order, so that `yearx
    /// 2024` is refused as the year line hledger stops in.
    ///
    /// An indented line only reaches the top level of `parse` from outside
    /// every dated entry, since `parseTransaction` takes the ones under a
    /// header and stops at the first blank or whitespace-only line. Out here
    /// it is the subdirective of a block above it, or it belongs to nothing.
    /// The most common line of the second kind is a posting a blank line cut
    /// off from its entry, often one of nothing but spaces that an editor
    /// left in the middle of the entry. Kept as a directive, that posting was
    /// left out of every report without a word, where hledger refuses the
    /// file at the line (issue #92), so the parser refuses it too. A
    /// subdirective is read only under a `commodity` block, where a `format`
    /// line states the style and hledger refuses one with no sample amount
    /// or with text after it (issue #106). Under every other block hledger
    /// skips what it does not know, `format` included, and so does the
    /// parser; read there, a `format` line under an `account` block declared
    /// that account's commodity style (issue #111).
    func declare(at index: Int, in lines: [String], into style: inout JournalStyleCollector, year: inout Int?) throws {
        let line = lines[index]
        guard let first = line.unicodeScalars.first, first == " " || first == "\t" else {
            try declare(from: line, into: &style, year: &year)
            try requireKnownDirective(line, lineNumber: index + 1)
            return
        }
        guard let owner = indentedLineOwner(at: index, in: lines) else {
            throw LedgerError.parseError(
                line: index + 1,
                message: "This indented line belongs to no entry or directive above it",
            )
        }
        if owner == "commodity" { try declareFormat(from: line, into: &style) }
    }

    /// The keyword of the block that owns the indented line at `index`, read
    /// upwards from the line above it, or `nil` when no block above it takes
    /// indented lines.
    ///
    /// The indented lines above are the block's own and are passed over, an
    /// indented comment among them. A blank line ends every block, and so
    /// does any other line at the margin, a full-line comment included, the
    /// first of which is the line that opened the block. A line of nothing
    /// but spaces ends an entry, as it ends a dated one, but not a directive's
    /// block, which hledger reads straight past it.
    private func indentedLineOwner(at index: Int, in lines: [String]) -> String? {
        var crossedWhitespaceLine = false
        for line in lines[..<index].reversed() {
            if line.isEmpty { return nil }
            guard let first = line.unicodeScalars.first, first == " " || first == "\t" else {
                return blockKeyword(of: line, acrossWhitespaceLine: crossedWhitespaceLine)
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { crossedWhitespaceLine = true }
        }
        return nil
    }

    /// The keyword of the block a line at the margin opens, `~` or `=` for
    /// the entry forms, or `nil` when it opens none, as hledger reads them.
    ///
    /// The `account`, `commodity`, `payee` and `tag` directives take
    /// subdirectives on the lines below them. A periodic (`~`) or automated
    /// (`=`) entry takes postings, and ends at a whitespace-only line as a
    /// dated entry does. A `commodity` line that states a sample amount is the
    /// one-line form, complete on its line, and hledger refuses an indented
    /// line under it; a digit inside a quoted symbol, `commodity "AAPL 2"`,
    /// names the commodity and states nothing, and so does a digit outside
    /// ASCII, `commodity m²`, which hledger never reads as part of a number.
    /// A dated header is not in the list: `parseTransaction` has taken every
    /// line it owns, so the walk up reaches one only across the line that
    /// ended it.
    private func blockKeyword(of line: String, acrossWhitespaceLine: Bool) -> String? {
        if line.hasPrefix("~") || line.hasPrefix("=") { return acrossWhitespaceLine ? nil : String(line.prefix(1)) }
        guard let keyword = ["account", "commodity", "payee", "tag"].first(where: {
            line.hasPrefix($0) && [" ", "\t"].contains(line.dropFirst($0.count).first)
        }) else { return nil }
        guard keyword == "commodity" else { return keyword }
        let (sample, _) = splitPostingComment(String(line.dropFirst(keyword.count)))
        return (sample ?? "").firstIndex(outsideQuotes: { ("0" ... "9").contains($0) }) == nil ? keyword : nil
    }
}
