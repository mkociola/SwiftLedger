// MARK: - Which indented lines outside an entry belong to something

import Foundation

extension JournalParser {
    /// The line at `index`, refused when it is indented and nothing above it
    /// can own it.
    ///
    /// An indented line only reaches the top level of `parse` from outside
    /// every dated entry, since `parseTransaction` takes the ones under a
    /// header and stops at the first blank or whitespace-only line. Out here
    /// it is the subdirective of a block above it, or it belongs to nothing.
    /// The most common line of the second kind is a posting a blank line cut
    /// off from its entry, often one of nothing but spaces that an editor
    /// left in the middle of the entry. Kept as a directive, that posting was
    /// left out of every report without a word, where hledger refuses the
    /// file at the line (issue #92), so the parser refuses it too.
    func ownedLine(at index: Int, in lines: [String]) throws -> String {
        let line = lines[index]
        guard let first = line.unicodeScalars.first, first == " " || first == "\t" else { return line }
        guard !indentedLineHasOwner(at: index, in: lines) else { return line }
        throw LedgerError.parseError(
            line: index + 1,
            message: "This indented line belongs to no entry or directive above it",
        )
    }

    /// Whether the block the indented line at `index` stands in is one that
    /// takes indented lines, read upwards from the line above it.
    ///
    /// The indented lines above are the block's own and are passed over, an
    /// indented comment among them. A blank line ends every block, and so
    /// does any other line at the margin, a full-line comment included, the
    /// first of which is the line that opened the block. A line of nothing
    /// but spaces ends an entry, as it ends a dated one, but not a directive's
    /// block, which hledger reads straight past it.
    private func indentedLineHasOwner(at index: Int, in lines: [String]) -> Bool {
        var crossedWhitespaceLine = false
        for line in lines[..<index].reversed() {
            if line.isEmpty { return false }
            guard let first = line.unicodeScalars.first, first == " " || first == "\t" else {
                return ownsIndentedLines(line, acrossWhitespaceLine: crossedWhitespaceLine)
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { crossedWhitespaceLine = true }
        }
        return false
    }

    /// Whether a line at the margin opens a block of indented lines, as hledger
    /// reads them.
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
    private func ownsIndentedLines(_ line: String, acrossWhitespaceLine: Bool) -> Bool {
        if line.hasPrefix("~") || line.hasPrefix("=") { return !acrossWhitespaceLine }
        guard let keyword = ["account", "commodity", "payee", "tag"].first(where: {
            line.hasPrefix($0) && [" ", "\t"].contains(line.dropFirst($0.count).first)
        }) else { return false }
        guard keyword == "commodity" else { return true }
        let (sample, _) = splitPostingComment(String(line.dropFirst(keyword.count)))
        return (sample ?? "").firstIndex(outsideQuotes: { ("0" ... "9").contains($0) }) == nil
    }
}
