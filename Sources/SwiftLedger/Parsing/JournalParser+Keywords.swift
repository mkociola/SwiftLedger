// MARK: - Which lines at the margin hledger reads at all

import Foundation

extension JournalParser {
    /// The words a line at the margin may open with and still be a line
    /// hledger reads: its own directives, the ledger-cli directives it
    /// accepts and passes over (`apply fixed`, `assert`, `bucket`, `capture`,
    /// `check`, `define`, `eval`, `expr`, `python`, `value`), and the `end`
    /// that closes the block forms. A `comment` or `test` block is read by
    /// `parse` before this is asked, and so is an `account` line that names
    /// an account; `account` stands here for the nameless line
    /// `parseAccountDirective` leaves alone. Each word is followed by the end
    /// of the line, a space or a tab, as hledger reads them, so
    /// `decimal-markx` opens nothing. Checked against hledger 1.52.4.
    private static let keywords: Set<String> = [
        "A", "account", "alias", "apply", "assert", "bucket", "capture", "check", "commodity", "decimal-mark",
        "define", "end", "eval", "expr", "include", "payee", "python", "tag", "value", "year",
    ]

    /// The directives hledger reads from their first character alone, the
    /// rest of the line following with or without a gap: `Y2024` sets the
    /// year as `Y 2024` does, and `P2024-01-01 $ 1` is a price. What follows
    /// is read elsewhere: a `D` or `Y` line that cannot be read is refused by
    /// `declare`, and a `P`, `N` or `C` line is kept as it came.
    private static let letterDirectives: Set<Character> = ["D", "Y", "P", "N", "C"]

    /// Refuses a line at the margin that opens with no word hledger reads, at
    /// its line, as hledger refuses it (issue #104).
    ///
    /// Only a line the earlier branches of `parse` left alone gets here: not
    /// blank, not a comment, not a block, not an `account` line and not a
    /// dated entry. Of those, hledger reads a periodic (`~`) or automated
    /// (`=`) entry, a directive opening with one of the words above or with a
    /// `!` straight in front of one, a `D`, `Y`, `P`, `N` or `C` line, and a
    /// line opening `--`, which it passes over as a comment. Anything else is
    /// a typo it stops at, and kept, the typo changed what the file says
    /// without a word: `decimal-markx ,` declared no comma, and every `€1.000`
    /// below it was a euro rather than a thousand. `ownedLine` asks for every
    /// line at the margin, after `declare` has read it, so a `D` or `year`
    /// line that cannot be read is refused as that directive rather than as
    /// an unknown word; an indented line is a subdirective of the block above
    /// it, or refused there, and is not asked.
    func requireKnownDirective(_ line: String, lineNumber: Int) throws {
        guard let first = line.first else { return }
        if first == "~" || first == "=" || line.hasPrefix("--") { return }
        let body = first == "!" ? line.dropFirst() : line[...]
        if let opener = body.first, Self.letterDirectives.contains(opener) { return }
        let word = body.prefix { $0 != " " && $0 != "\t" }
        guard Self.keywords.contains(String(word)) else {
            throw LedgerError.parseError(
                line: lineNumber,
                message: "Expected a dated entry, a directive or a comment, got '\(Self.entryHeader(line))'",
            )
        }
    }
}
