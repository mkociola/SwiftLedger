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
        var index = 0

        while index < lines.count {
            let raw  = lines[index]
            let line = raw

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(.blank)
                index += 1
                continue
            }

            // Full-line comment
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") && !startsWithDate(trimmed) {
                items.append(.comment(trimmed))
                index += 1
                continue
            }

            // account directive
            if trimmed.lowercased().hasPrefix("account ") {
                let name = String(trimmed.dropFirst("account ".count)).trimmingCharacters(in: .whitespaces)
                items.append(.accountDirective(AccountDirective(name: name)))
                index += 1
                continue
            }

            // Transaction header (starts with a date)
            if startsWithDate(trimmed) {
                let (transaction, consumed) = try parseTransaction(lines: lines, from: index)
                items.append(.transaction(transaction))
                index += consumed
                continue
            }

            // Unknown line — treat as comment for forward compatibility
            items.append(.comment(trimmed))
            index += 1
        }

        return Journal(items: items)
    }

    // MARK: - Transaction parsing

    private struct ParsedHeader {
        var date: JournalDate
        var auxDate: JournalDate?
        var status: ClearingStatus
        var code: String?
        var description: String
        var comment: String?
    }

    private func parseTransaction(lines: [String], from start: Int) throws -> (Transaction, Int) {
        let headerLine = lines[start]
        let lineNumber = start + 1 // 1-based for errors

        let header = try parseHeader(headerLine, lineNumber: lineNumber)

        // Collect posting lines (lines that begin with whitespace)
        var postingLines: [(String, Int)] = []
        var index = start + 1
        while index < lines.count {
            let currentLine = lines[index]
            if currentLine.isEmpty || currentLine.trimmingCharacters(in: .whitespaces).isEmpty {
                break  // blank line ends the transaction
            }
            let first = currentLine.unicodeScalars.first
            guard first == " " || first == "\t" else { break }
            postingLines.append((currentLine, index + 1))
            index += 1
        }

        let postings = try resolveElisions(try postingLines.map { try parsePosting($0.0, lineNumber: $0.1) })
        let transaction = try Transaction(
            date: header.date,
            auxDate: header.auxDate,
            status: header.status,
            code: header.code,
            description: header.description,
            postings: postings,
            comment: header.comment
        )
        return (transaction, index - start)
    }

    // MARK: - Header parsing

    private func parseHeader(
        _ line: String,
        lineNumber: Int
    ) throws -> ParsedHeader {

        var rest = line

        // Extract inline comment
        let (mainPart, comment) = splitInlineComment(rest)
        rest = mainPart.trimmingCharacters(in: .init(charactersIn: " \t"))

        // DATE
        let (date, afterDate) = try consumeDate(rest, lineNumber: lineNumber)
        rest = afterDate.trimmingCharacters(in: .whitespaces)

        // Optional = AUXDATE
        var auxDate: JournalDate?
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
        var code: String?
        if rest.hasPrefix("(") {
            if let closeIdx = rest.firstIndex(of: ")") {
                code = String(rest[rest.index(after: rest.startIndex)..<closeIdx])
                rest = String(rest[rest.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        let description = rest.trimmingCharacters(in: .whitespaces)
        return ParsedHeader(
            date: date,
            auxDate: auxDate,
            status: txStatus,
            code: code,
            description: description,
            comment: comment?.trimmingCharacters(in: .whitespaces)
        )
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
        var postingStatus: ClearingStatus?
        if rest.hasPrefix("* ") || rest.hasPrefix("! ") {
            postingStatus = rest.hasPrefix("*") ? .cleared : .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Account name ends at 2+ spaces, or at end of line
        let (accountName, amountStr) = splitAccountAndAmount(rest)

        var amount: Amount?
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
            return try rawPostings.map { raw in
                guard let amount = raw.amount else { throw LedgerError.cannotResolveElision }
                return Posting(accountName: raw.accountName, amount: amount, status: raw.status, comment: raw.comment)
            }
        }

        // Exactly one elided posting: compute its amount
        let explicitAmounts = rawPostings.compactMap { $0.amount }
        let commodities = Set(explicitAmounts.map { $0.commodity })
        guard commodities.count == 1,
              let commodity = commodities.first,
              let firstAmount = explicitAmounts.first else { throw LedgerError.cannotResolveElision }

        let isPrefix     = firstAmount.commodityIsPrefix
        let sum          = explicitAmounts.reduce(Decimal.zero) { $0 + $1.quantity }
        let elidedAmount     = Amount(quantity: -sum, commodity: commodity, commodityIsPrefix: isPrefix)

        return rawPostings.map { raw in
            let amt = raw.amount ?? elidedAmount
            return Posting(accountName: raw.accountName, amount: amt, status: raw.status, comment: raw.comment)
        }
    }

    // MARK: - Amount parsing

    /// Parses an amount string such as `$100`, `-$50`, `$-50`, `100 USD`, `100.00`.
    func parseAmount(_ raw: String, lineNumber: Int) throws -> Amount {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.invalidAmount(raw) }

        var str = trimmed
        var sign = Decimal(1)
        if str.hasPrefix("-") {
            sign = -1
            str = String(str.dropFirst())
        } else if str.hasPrefix("+") {
            str = String(str.dropFirst())
        }

        guard let firstChar = str.unicodeScalars.first else { throw LedgerError.invalidAmount(raw) }
        if !CharacterSet.decimalDigits.union(.init(charactersIn: ".")).contains(firstChar) {
            return try parsePrefixCommodityAmount(str, sign: sign, raw: raw)
        }
        return try parseSuffixCommodityAmount(str, sign: sign, raw: raw)
    }

    private func parsePrefixCommodityAmount(_ str: String, sign: Decimal, raw: String) throws -> Amount {
        var commodityEnd = str.endIndex
        for idx in str.indices {
            let char = str[idx]
            if char.isNumber || char == "." || char == "-" || char == "+" {
                commodityEnd = idx
                break
            }
        }
        let commodity = String(str[..<commodityEnd])
        var numStr = String(str[commodityEnd...])
        var adjustedSign = sign
        if numStr.hasPrefix("-") {
            adjustedSign *= -1
            numStr = String(numStr.dropFirst())
        } else if numStr.hasPrefix("+") {
            numStr = String(numStr.dropFirst())
        }
        numStr = numStr.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let quantity = Decimal(string: numStr) else { throw LedgerError.invalidAmount(raw) }
        return Amount(quantity: adjustedSign * quantity, commodity: commodity, commodityIsPrefix: true)
    }

    private func parseSuffixCommodityAmount(_ str: String, sign: Decimal, raw: String) throws -> Amount {
        var end = str.startIndex
        for idx in str.indices {
            let char = str[idx]
            if char.isNumber || char == "." || char == "," {
                end = str.index(after: idx)
            } else {
                break
            }
        }
        let numStr = String(str[..<end]).replacingOccurrences(of: ",", with: "")
        let remainder = String(str[end...]).trimmingCharacters(in: .whitespaces)
        guard let quantity = Decimal(string: numStr) else { throw LedgerError.invalidAmount(raw) }
        let commodity = remainder.isEmpty ? "USD" : remainder
        return Amount(quantity: sign * quantity, commodity: commodity, commodityIsPrefix: false)
    }
}
