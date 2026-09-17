// MARK: - Parsing utilities

import Foundation

extension JournalParser {
    func startsWithDate(_ str: String) -> Bool {
        // Quick check: at least 10 chars matching YYYY[-/]MM[-/]DD
        guard str.count >= 10 else { return false }
        let digits = str.prefix(10)
        let separators: Set<Character> = ["-", "/"]
        let chars = Array(digits)
        return chars[0].isNumber && chars[1].isNumber && chars[2].isNumber && chars[3].isNumber &&
            separators.contains(chars[4]) &&
            chars[5].isNumber && chars[6].isNumber &&
            separators.contains(chars[7]) &&
            chars[8].isNumber && chars[9].isNumber
    }

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
    /// back byte for byte; a whitespace-only line among them becomes `.blank`,
    /// exactly as it would at the top level, and writes back the same either
    /// way.
    func parseCommentBlock(lines: [String], from start: Int) -> [JournalItem] {
        var items: [JournalItem] = [.directive(lines[start])]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            items.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? .blank : .directive(line))
            index += 1
            if isCommentBlockEnd(line) { break }
        }
        return items
    }

    /// `line` with the `\r` a Windows line ending leaves on it taken off.
    ///
    /// `parse` splits the file on `\n` alone, so in a CRLF journal every line
    /// arrives with the other half of its ending still attached, and any field
    /// that runs to the end of its line would carry the `\r` into the
    /// transaction: a description of `"Rent\r"`, an elided posting to
    /// `"Assets:Checking\r"` that names no account any other entry names.
    /// `Transaction.init` refuses a field with a line break in it, so the
    /// stripping and that refusal have to arrive together.
    ///
    /// Only the last scalar, only when it is a `\r`, and only once. A `\r`
    /// anywhere else on the line is not a line ending, and the field it lands
    /// in really is one a journal cannot write, so it goes on to be refused by
    /// name. The raw lines are what `sourceText` is built from either way, so
    /// an entry nobody edits still goes back byte for byte.
    ///
    /// It also puts the amount column the style collector learns back where
    /// the file draws it: the field it measures used to be one character wider
    /// than it looked whenever an amount ended a CRLF line.
    func contentOf(line: String) -> String {
        guard line.unicodeScalars.last == "\r" else { return line }
        var scalars = line.unicodeScalars
        scalars.removeLast()
        return String(scalars)
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

    func consumeDate(_ str: String, lineNumber: Int) throws -> (JournalDate, String) {
        guard str.count >= 10 else {
            throw LedgerError.parseError(line: lineNumber, message: "Expected date, got '\(str)'")
        }
        let dateStr = String(str.prefix(10))
        let rest = String(str.dropFirst(10))

        let parts = dateStr.components(separatedBy: CharacterSet(charactersIn: "-/"))
        // swiftlint:disable identifier_name
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else {
            throw LedgerError.invalidDate(dateStr)
        }
        let date = try JournalDate(year: y, month: m, day: d)
        // swiftlint:enable identifier_name
        return (date, rest)
    }

    /// Splits the inline comment off a transaction header or an `account`
    /// directive: two or more spaces, then `;`.
    ///
    /// A posting line goes through `splitPostingComment` instead, which takes
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
