import Foundation

/// Parses a plain-text `.ledger` / `.journal` file into a `Journal` value.
///
/// Supported grammar:
/// ```
/// DATE [= AUXDATE] [* | !] [(CODE)] DESCRIPTION [  ; comment]
///     [* | !] ACCOUNT_NAME  [AMOUNT] [  ; comment]
///     [* | !] ACCOUNT_NAME  [AMOUNT] [  ; comment]
/// ```
///
/// - Date formats: `YYYY-MM-DD` or `YYYY/MM/DD`
/// - Amount formats: `$100`, `-$50`, `$-50`, `100 USD`, `100.00 EUR`, `£500`
/// - Status: `*` = cleared, `!` = pending
/// - Comments: `;` or `#` at line start; inline `  ;` after 2+ spaces
/// - `account NAME` directives
/// - Blank lines and full-line comments are preserved in the AST.
public struct JournalParser {

    public init() {}

    // MARK: - Public API

    /// Parses `text` and returns a `Journal`.
    public func parse(_ text: String) throws -> Journal {
        let lines = text.components(separatedBy: "\n")
        var items: [JournalItem] = []
        var i = 0

        while i < lines.count {
            let raw  = lines[i]
            let line = raw

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(.blank)
                i += 1
                continue
            }

            // Full-line comment
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") && !startsWithDate(trimmed) {
                items.append(.comment(trimmed))
                i += 1
                continue
            }

            // account directive
            if trimmed.lowercased().hasPrefix("account ") {
                let name = String(trimmed.dropFirst("account ".count)).trimmingCharacters(in: .whitespaces)
                items.append(.accountDirective(AccountDirective(name: name)))
                i += 1
                continue
            }

            // Transaction header (starts with a date)
            if startsWithDate(trimmed) {
                let (tx, consumed) = try parseTransaction(lines: lines, from: i)
                items.append(.transaction(tx))
                i += consumed
                continue
            }

            // Unknown line — treat as comment for forward compatibility
            items.append(.comment(trimmed))
            i += 1
        }

        return Journal(items: items)
    }

    // MARK: - Transaction parsing

    private func parseTransaction(lines: [String], from start: Int) throws -> (Transaction, Int) {
        let headerLine = lines[start]
        let lineNumber = start + 1 // 1-based for errors

        let (date, auxDate, status, code, description, headerComment) = try parseHeader(headerLine, lineNumber: lineNumber)

        // Collect posting lines (lines that begin with whitespace)
        var postingLines: [(String, Int)] = []
        var i = start + 1
        while i < lines.count {
            let l = lines[i]
            if l.isEmpty || l.trimmingCharacters(in: .whitespaces).isEmpty {
                break  // blank line ends the transaction
            }
            let first = l.unicodeScalars.first
            guard first == " " || first == "\t" else { break }
            postingLines.append((l, i + 1))
            i += 1
        }

        let postings = try resolveElisions(try postingLines.map { try parsePosting($0.0, lineNumber: $0.1) })
        let tx = try Transaction(
            date: date,
            auxDate: auxDate,
            status: status,
            code: code,
            description: description,
            postings: postings,
            comment: headerComment
        )
        return (tx, i - start)
    }

    // MARK: - Header parsing

    private func parseHeader(
        _ line: String,
        lineNumber: Int
    ) throws -> (JournalDate, JournalDate?, ClearingStatus, String?, String, String?) {

        var rest = line

        // Extract inline comment
        let (mainPart, comment) = splitInlineComment(rest)
        rest = mainPart.trimmingCharacters(in: .init(charactersIn: " \t"))

        // DATE
        let (date, afterDate) = try consumeDate(rest, lineNumber: lineNumber)
        rest = afterDate.trimmingCharacters(in: .whitespaces)

        // Optional = AUXDATE
        var auxDate: JournalDate? = nil
        if rest.hasPrefix("=") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            let (aux, afterAux) = try consumeDate(rest, lineNumber: lineNumber)
            auxDate = aux
            rest = afterAux.trimmingCharacters(in: .whitespaces)
        }

        // Optional status (* or !)
        var txStatus: ClearingStatus = .unmarked
        if rest.hasPrefix("*") {
            txStatus = .cleared
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("!") {
            txStatus = .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Optional (CODE)
        var code: String? = nil
        if rest.hasPrefix("(") {
            if let closeIdx = rest.firstIndex(of: ")") {
                code = String(rest[rest.index(after: rest.startIndex)..<closeIdx])
                rest = String(rest[rest.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        let description = rest.trimmingCharacters(in: .whitespaces)
        return (date, auxDate, txStatus, code, description, comment?.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Posting parsing

    private struct RawPosting {
        var accountName: String
        var amount: Amount?
        var status: ClearingStatus?
        var comment: String?
    }

    private func parsePosting(_ line: String, lineNumber: Int) throws -> RawPosting {
        var rest = line.trimmingCharacters(in: .whitespaces)

        // Extract inline comment (2+ spaces then ;)
        let (mainPart, comment) = splitInlineComment(rest)
        rest = mainPart.trimmingCharacters(in: .init(charactersIn: " \t"))

        // Optional status (* or !)
        var postingStatus: ClearingStatus? = nil
        if rest.hasPrefix("* ") || rest.hasPrefix("! ") {
            postingStatus = rest.hasPrefix("*") ? .cleared : .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Account name ends at 2+ spaces, or at end of line
        let (accountName, amountStr) = splitAccountAndAmount(rest)

        var amount: Amount? = nil
        if let rawAmount = amountStr {
            amount = try parseAmount(rawAmount, lineNumber: lineNumber)
        }

        return RawPosting(
            accountName: accountName,
            amount: amount,
            status: postingStatus,
            comment: comment?.trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: - Elision resolution

    private func resolveElisions(_ rawPostings: [RawPosting]) throws -> [Posting] {
        let elidedCount = rawPostings.filter { $0.amount == nil }.count
        guard elidedCount <= 1 else { throw LedgerError.multipleElidedPostings }

        if elidedCount == 0 {
            return rawPostings.map {
                Posting(accountName: $0.accountName, amount: $0.amount!, status: $0.status, comment: $0.comment)
            }
        }

        // Exactly one elided posting: compute its amount
        let explicit = rawPostings.filter { $0.amount != nil }
        let commodities = Set(explicit.map { $0.amount!.commodity })
        guard commodities.count == 1 else { throw LedgerError.cannotResolveElision }

        let commodity        = commodities.first!
        let isPrefix         = explicit.first!.amount!.commodityIsPrefix
        let sum              = explicit.reduce(Decimal.zero) { $0 + $1.amount!.quantity }
        let elidedAmount     = Amount(quantity: -sum, commodity: commodity, commodityIsPrefix: isPrefix)

        return rawPostings.map { raw in
            let amt = raw.amount ?? elidedAmount
            return Posting(accountName: raw.accountName, amount: amt, status: raw.status, comment: raw.comment)
        }
    }

    // MARK: - Amount parsing

    /// Parses an amount string such as `$100`, `-$50`, `$-50`, `100 USD`, `100.00`.
    func parseAmount(_ raw: String, lineNumber: Int) throws -> Amount {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw LedgerError.invalidAmount(raw) }

        // Detect leading sign
        var str   = s
        var sign  = Decimal(1)
        if str.hasPrefix("-") {
            sign = -1
            str  = String(str.dropFirst())
        } else if str.hasPrefix("+") {
            str = String(str.dropFirst())
        }

        // Prefix commodity: starts with a non-digit / non-period character
        let firstChar = str.unicodeScalars.first!
        if !CharacterSet.decimalDigits.union(.init(charactersIn: ".")).contains(firstChar) {
            // Consume the commodity symbol (everything before the first digit or sign)
            var commodityEnd = str.startIndex
            for idx in str.indices {
                let c = str[idx]
                if c.isNumber || c == "." || c == "-" || c == "+" {
                    commodityEnd = idx
                    break
                }
                if idx == str.indices.last! {
                    commodityEnd = str.endIndex
                }
            }
            let commodity = String(str[..<commodityEnd])
            var numStr    = String(str[commodityEnd...])

            // Inner sign after commodity symbol (e.g. `$-50`)
            if numStr.hasPrefix("-") {
                sign  = sign * -1
                numStr = String(numStr.dropFirst())
            } else if numStr.hasPrefix("+") {
                numStr = String(numStr.dropFirst())
            }

            numStr = numStr.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            guard let quantity = Decimal(string: numStr) else {
                throw LedgerError.invalidAmount(raw)
            }
            return Amount(quantity: sign * quantity, commodity: commodity, commodityIsPrefix: true)
        }

        // Suffix commodity or bare number: scan digits/decimal first, then optional commodity
        var end = str.startIndex
        for idx in str.indices {
            let c = str[idx]
            if c.isNumber || c == "." || c == "," {
                end = str.index(after: idx)
            } else {
                break
            }
        }
        let numStr    = String(str[..<end]).replacingOccurrences(of: ",", with: "")
        let remainder = String(str[end...]).trimmingCharacters(in: .whitespaces)

        guard let quantity = Decimal(string: numStr) else {
            throw LedgerError.invalidAmount(raw)
        }

        let commodity    = remainder.isEmpty ? "USD" : remainder
        let isPrefix     = false
        return Amount(quantity: sign * quantity, commodity: commodity, commodityIsPrefix: isPrefix)
    }

    // MARK: - Utilities

    private func startsWithDate(_ s: String) -> Bool {
        // Quick check: at least 10 chars matching YYYY[-/]MM[-/]DD
        guard s.count >= 10 else { return false }
        let digits = s.prefix(10)
        let separators: Set<Character> = ["-", "/"]
        let chars = Array(digits)
        return chars[0].isNumber && chars[1].isNumber && chars[2].isNumber && chars[3].isNumber &&
               separators.contains(chars[4]) &&
               chars[5].isNumber && chars[6].isNumber &&
               separators.contains(chars[7]) &&
               chars[8].isNumber && chars[9].isNumber
    }

    private func consumeDate(_ s: String, lineNumber: Int) throws -> (JournalDate, String) {
        guard s.count >= 10 else { throw LedgerError.parseError(line: lineNumber, message: "Expected date, got '\(s)'") }
        let dateStr = String(s.prefix(10))
        let rest    = String(s.dropFirst(10))

        let parts = dateStr.components(separatedBy: CharacterSet(charactersIn: "-/"))
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            throw LedgerError.invalidDate(dateStr)
        }
        let date = try JournalDate(year: y, month: m, day: d)
        return (date, rest)
    }

    private func splitInlineComment(_ s: String) -> (String, String?) {
        // Inline comment: 2+ spaces followed by ;
        var prevWasSpace = false
        var prevPrevWasSpace = false
        for idx in s.indices {
            let c = s[idx]
            if c == ";" && prevWasSpace && prevPrevWasSpace {
                // Find actual start (back up to first of the 2+ spaces)
                var commentStart = idx
                var searchIdx    = s.index(before: idx)
                while searchIdx >= s.startIndex && (s[searchIdx] == " " || s[searchIdx] == "\t") {
                    commentStart = searchIdx
                    if searchIdx == s.startIndex { break }
                    searchIdx = s.index(before: searchIdx)
                }
                let main    = String(s[..<commentStart]).trimmingCharacters(in: .init(charactersIn: " \t"))
                let comment = String(s[s.index(after: idx)...])
                return (main, comment)
            }
            prevPrevWasSpace = prevWasSpace
            prevWasSpace     = (c == " " || c == "\t")
        }
        // Handle: line starts with "; " as full-line comment (no splitting needed)
        return (s, nil)
    }

    private func splitAccountAndAmount(_ s: String) -> (String, String?) {
        // Account name ends at 2+ consecutive spaces
        var lastNonSpaceIdx: String.Index? = nil
        var consecutiveSpaces = 0
        var splitIdx: String.Index? = nil

        for idx in s.indices {
            let c = s[idx]
            if c == " " || c == "\t" {
                consecutiveSpaces += 1
                if consecutiveSpaces >= 2 && splitIdx == nil {
                    splitIdx = idx
                }
            } else {
                consecutiveSpaces = 0
                lastNonSpaceIdx   = idx
            }
        }

        guard let split = splitIdx else {
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }

        // Find the start of the 2+-space run
        var runStart = split
        var check    = s.index(before: split)
        while check >= s.startIndex && (s[check] == " " || s[check] == "\t") {
            runStart = check
            if check == s.startIndex { break }
            check = s.index(before: check)
        }

        let account = String(s[..<runStart]).trimmingCharacters(in: .whitespaces)
        let amount  = String(s[s.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        return (account, amount.isEmpty ? nil : amount)
    }
}
