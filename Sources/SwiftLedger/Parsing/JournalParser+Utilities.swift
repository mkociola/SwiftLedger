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
