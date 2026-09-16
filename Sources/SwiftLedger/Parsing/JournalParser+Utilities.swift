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

    /// Whether `line` opens a `comment` block.
    ///
    /// The keyword stands alone at column 0, with nothing after it but
    /// whitespace: `comment foo` is a directive, and an indented `comment` is
    /// a posting or a sub-directive.
    func isCommentBlockStart(_ line: String) -> Bool {
        isBareKeywordLine(line, keyword: "comment")
    }

    /// Whether `line` closes a `comment` block, read the same way as the
    /// opening keyword. An indented `  end comment` is block content.
    func isCommentBlockEnd(_ line: String) -> Bool {
        isBareKeywordLine(line, keyword: "end comment")
    }

    private func isBareKeywordLine(_ line: String, keyword: String) -> Bool {
        guard line.hasPrefix(keyword) else { return false }
        return line.dropFirst(keyword.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Reads the `comment` block opening at `start` and returns one item per
    /// line it spans, the `comment` and `end comment` keywords included.
    ///
    /// The block runs to the first `end comment` at column 0, or to the end of
    /// the file when nothing closes it, as it does in ledger and hledger. Its
    /// lines are kept verbatim as directives so the file goes back byte for
    /// byte; a whitespace-only line among them becomes `.blank`, exactly as it
    /// would at the top level, and writes back the same either way.
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
}
