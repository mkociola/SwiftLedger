// MARK: - Parsing utilities

import Foundation

extension JournalParser {
    /// The markers that make a line outside a transaction a full-line comment.
    ///
    /// ledger and hledger read all five this way. `JournalSerializer` writes a
    /// comment back untouched when it starts with one of them, so the two
    /// lists have to say the same thing: widening one without the other would
    /// turn a parsed `% note` into `; % note` on the way out.
    static let fullLineCommentMarkers: Set<Character> = [";", "#", "*", "%", "|"]

    /// Whether a line outside a transaction is a full-line comment.
    ///
    /// Takes the line already trimmed: an indented `  ; note` between entries
    /// is a comment too, and keeps its indentation in the item.
    func isFullLineComment(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return false }
        return Self.fullLineCommentMarkers.contains(first)
    }

    /// Whether `line` opens a block comment: `comment` or `test` at column 0.
    ///
    /// Read as ledger reads it, which is by the line's first word: anything
    /// after the keyword is ignored, so `comment draft entries` opens a block
    /// just as a bare `comment` does. hledger is stricter and takes only the
    /// bare keyword, rejecting the rest outright, so no hledger journal
    /// contains a line this reading treats differently from hledger's. Getting
    /// it the other way round is what issue #17 is about: a ledger user's
    /// parked entries would be read as data and booked.
    ///
    /// The keyword is case-sensitive and must start the line: `Comment`,
    /// `comments` and an indented `  comment` are all something else.
    func isCommentBlockStart(_ line: String) -> Bool {
        ["comment", "test"].contains { startsWithKeyword(line, keyword: $0) }
    }

    /// Whether `line` closes a block comment, read the same way as the opening
    /// keyword. Either keyword closes either kind of block, as in ledger, and
    /// an indented `  end comment` is block content rather than its end.
    func isCommentBlockEnd(_ line: String) -> Bool {
        ["end comment", "end test"].contains { startsWithKeyword(line, keyword: $0) }
    }

    /// Whether `line` is `keyword` at column 0, standing alone (trailing
    /// spaces or tabs aside) or followed by whitespace and anything at all.
    /// The whitespace is what keeps `comments` from reading as `comment`.
    ///
    /// The line is one `parse` has taken the line ending off. With the `\r`
    /// of a Windows ending still on it, a bare keyword would read `comment\r`,
    /// and a `\r` is neither the end of the line nor a space: the keyword
    /// would open no block and the entries parked under it would be booked,
    /// which is issue #48.
    private func startsWithKeyword(_ line: String, keyword: String) -> Bool {
        guard line.hasPrefix(keyword) else { return false }
        let rest = line.dropFirst(keyword.count)
        guard let next = rest.first else { return true }
        return next == " " || next == "\t"
    }

    /// Reads the block comment opening at `start` and returns one item per
    /// line it spans, the opening and closing keyword lines included.
    ///
    /// The block runs to the first `end comment` or `end test` at column 0, or
    /// to the end of the file when nothing closes it, as in ledger and
    /// hledger. Its lines are kept verbatim as directives so the file goes
    /// back byte for byte, a whitespace-only line among them included; only
    /// an empty line becomes `.blank`, exactly as it would at the top level.
    ///
    /// hledger wants a newline after every line of a block, the closing
    /// keyword included, and refuses a file whose last line belongs to one and
    /// has none, so this refuses it too, at that line (issue #66). Whether the
    /// file ends in a newline is asked of the text rather than of `lines`: a
    /// stray `\r` at the very end is an empty last line there, and still no
    /// newline to hledger.
    func parseCommentBlock(lines: [String], from start: Int, fileEndsInNewline: Bool) throws -> [JournalItem] {
        var items: [JournalItem] = [.directive(lines[start])]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            items.append(line.isEmpty ? .blank : .directive(line))
            index += 1
            if isCommentBlockEnd(line) { break }
        }
        if start + items.count == lines.count, !fileEndsInNewline {
            throw LedgerError.parseError(
                line: lines.count,
                message: "The file ends on a line of a block comment with no newline after it",
            )
        }
        return items
    }

    /// Whether an indented line inside a transaction is a full-line comment
    /// rather than a posting.
    ///
    /// Only `;` and `#` mark a comment here: a leading `*` or `!` inside a
    /// transaction is a posting status marker, unlike at the top level where
    /// `*` starts a comment too (see `fullLineCommentMarkers`).
    func isTransactionComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(";") || trimmed.hasPrefix("#")
    }

    /// Splits the inline comment off an `account` directive: two or more
    /// spaces, then `;`.
    ///
    /// A transaction header opens its comment at the first `;` past the code,
    /// as hledger reads it, and `parseHeader` splits it there itself. A
    /// posting line goes through `splitPostingComment` instead, which takes
    /// a `;` after one space as well. The two-space rule is there to end an
    /// account name, and past the name a posting line is an amount field,
    /// where ledger and hledger open a comment at the first `;` however few
    /// spaces come before it.
    func splitInlineComment(_ str: String) -> (String, String?) {
        // Inline comment: 2+ spaces followed by ;
        var prevWasSpace = false
        var prevPrevWasSpace = false
        for idx in str.indices {
            let char = str[idx]
            if char == ";", prevWasSpace, prevPrevWasSpace {
                // Find actual start (back up to first of the 2+ spaces)
                var commentStart = idx
                var searchIdx = str.index(before: idx)
                while searchIdx >= str.startIndex, str[searchIdx] == " " || str[searchIdx] == "\t" {
                    commentStart = searchIdx
                    if searchIdx == str.startIndex { break }
                    searchIdx = str.index(before: searchIdx)
                }
                let main = String(str[..<commentStart]).trimmingCharacters(in: .init(charactersIn: " \t"))
                let comment = String(str[str.index(after: idx)...])
                return (main, comment)
            }
            prevPrevWasSpace = prevWasSpace
            prevWasSpace = (char == " " || char == "\t")
        }
        return (str, nil)
    }

    func splitAccountAndAmount(_ str: String) -> (String, String?) {
        // Account name ends at 2+ consecutive spaces
        var consecutiveSpaces = 0
        var splitIdx: String.Index?

        for idx in str.indices {
            let char = str[idx]
            if char == " " || char == "\t" {
                consecutiveSpaces += 1
                if consecutiveSpaces >= 2, splitIdx == nil {
                    splitIdx = idx
                }
            } else {
                consecutiveSpaces = 0
            }
        }

        guard let split = splitIdx else {
            return (str.trimmingCharacters(in: .whitespaces), nil)
        }

        // Find the start of the 2+-space run
        var runStart = split
        var check = str.index(before: split)
        while check >= str.startIndex, str[check] == " " || str[check] == "\t" {
            runStart = check
            if check == str.startIndex { break }
            check = str.index(before: check)
        }

        let account = String(str[..<runStart]).trimmingCharacters(in: .whitespaces)
        let amount = String(str[str.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        return (account, amount.isEmpty ? nil : amount)
    }

    /// Splits text at the first `;` into what comes before it and the comment
    /// the `;` opens.
    ///
    /// A posting's amount field is cut this way: `    expenses    $66.00 ; an
    /// expense` is an amount and a comment in ledger and in hledger, and one
    /// space before the `;` is enough, because the two spaces belong to the
    /// rule that ends the account name and that rule has already done its work
    /// by the time this is called. Reading the line the other way is what
    /// issue #18 reported from a real journal, where the amount came through
    /// as 66, the comment was dropped without a word, and any edit to the
    /// entry wrote the line back without it.
    ///
    /// The sample amount of a `D`, `commodity` or `format` directive is cut
    /// the same way: `D $1,000.00 ; house style` states a style and says why,
    /// and the amount parser must be handed the style alone.
    ///
    /// Everything from the first `;` is the comment, so a `;` inside one stays
    /// inside it. The text comes back `nil` when there is nothing but the
    /// comment, which is the `Assets:Checking  ; note` line that writes no
    /// amount at all, and is trimmed either way.
    func splitPostingComment(_ field: String?) -> (String?, String?) {
        guard let field else { return (nil, nil) }
        guard let marker = field.firstIndex(of: ";") else {
            let text = field.trimmingCharacters(in: .whitespaces)
            return (text.isEmpty ? nil : text, nil)
        }
        let text = String(field[..<marker]).trimmingCharacters(in: .whitespaces)
        return (text.isEmpty ? nil : text, String(field[field.index(after: marker)...]))
    }
}
