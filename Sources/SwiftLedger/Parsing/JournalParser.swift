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
/// - A posting amount may be followed by a price (`@` per unit, `@@` total)
///   and/or a balance assertion (`=`), in that order, each written in either
///   commodity style: `10 AAPL @ $150.00 = 30 AAPL`. Prices take part in
///   balancing; assertions are preserved but never checked.
/// - Status: `*` = cleared, `!` = pending
/// - Comments: `;` or `#` at line start; inline `  ;` after 2+ spaces
/// - `account NAME` directives, with an optional inline comment
/// - Blank lines and full-line comments are preserved in the AST.
/// - Every parsed transaction keeps its own source lines verbatim
///   (`Transaction.sourceText`), so serialising a journal nobody edited
///   reproduces the file byte for byte.
/// - Indented full-line comments inside a transaction are commentary, not
///   postings: they are preserved verbatim on the posting above them, or on
///   the transaction when they precede the first posting.
///
/// Any line outside this grammar — `include`, `P`, `commodity`, `alias`, `D`,
/// `year`, an indented sub-directive, or anything else — is kept verbatim as a
/// `.directive` item and written back unchanged by `JournalSerializer`. The
/// parser never reinterprets what it does not understand.
public struct JournalParser {
    public init() {}

    // MARK: - Public API

    /// Parses `text` and returns a `Journal`.
    public func parse(_ text: String) throws -> Journal {
        let lines = text.components(separatedBy: "\n")
        var items: [JournalItem] = []
        // Watches how the file writes each commodity, so that a transaction
        // the caller later rebuilds is written the same way.
        var formats = CommodityFormatCollector()
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let line = raw

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(.blank)
                index += 1
                continue
            }

            // Full-line comment — stored verbatim so indentation survives a round-trip.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") && !startsWithDate(trimmed) {
                items.append(.comment(line))
                index += 1
                continue
            }

            // account directive, with its inline comment split off so the
            // comment text never becomes part of the declared account name.
            if trimmed.lowercased().hasPrefix("account ") {
                let (mainPart, comment) = splitInlineComment(trimmed)
                let name = String(mainPart.dropFirst("account ".count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let directive = AccountDirective(
                        name: name,
                        comment: comment?.trimmingCharacters(in: .whitespaces),
                    )
                    items.append(.accountDirective(directive))
                    index += 1
                    continue
                }
                // A nameless `account` line is not a directive we can model;
                // fall through and keep it verbatim.
            }

            // Transaction header (starts with a date)
            if startsWithDate(trimmed) {
                let (transaction, consumed) = try parseTransaction(lines: lines, from: index, into: &formats)
                items.append(.transaction(transaction))
                index += consumed
                continue
            }

            // Anything else — an unsupported directive (`include`, `P`, `commodity`,
            // `alias`, `D`, `year`, an indented sub-directive) or malformed content.
            // Kept verbatim so serialising never rewrites what we cannot interpret.
            // A `D` or `commodity` line is read for the display style it states
            // and kept verbatim all the same: learning from a line is not the
            // same as modelling it, and this one still goes back byte for byte.
            declareFormat(from: line, into: &formats)
            items.append(.directive(line))
            index += 1
        }

        return Journal(items: items, commodityFormats: formats.formats)
    }

    // MARK: - Declared display styles

    /// Reads the display style a `D` or `commodity` directive states, if the
    /// line is one.
    ///
    /// ledger and hledger both spell a style as a sample amount, in three
    /// places: `D $1,000.00`, the one-line `commodity $1,000.00`, and the
    /// indented `format $1,000.00` inside a `commodity` block. An indented line
    /// can only reach here from such a block — the ones inside a transaction
    /// are consumed with it — so no block tracking is needed to tell them
    /// apart.
    ///
    /// Anything that does not parse as an amount is left alone. A directive
    /// SwiftLedger misreads here costs nothing but the guess: the line itself
    /// is still written back verbatim.
    private func declareFormat(from line: String, into formats: inout CommodityFormatCollector) {
        let isIndented = line.first == " " || line.first == "\t"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let keyword = ["D ", "commodity ", "format "].first { trimmed.hasPrefix($0) }
        guard let keyword else { return }
        guard keyword != "format " || isIndented else { return }

        let sample = String(trimmed.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        // `commodity $` names a commodity without stating a style; only the
        // sample-amount forms say anything to record.
        guard sample.contains(where: \.isNumber),
              let amount = try? parseAmount(sample, lineNumber: 0),
              !amount.commodity.isEmpty else { return }
        formats.declare(sample, commodity: amount.commodity)
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

    private func parseTransaction(
        lines: [String],
        from start: Int,
        into formats: inout CommodityFormatCollector,
    ) throws -> (Transaction, Int) {
        let headerLine = lines[start]
        let lineNumber = start + 1 // 1-based for errors

        let header = try parseHeader(headerLine, lineNumber: lineNumber)

        // Collect the transaction body: the indented lines below the header.
        // A full-line comment among them is commentary rather than a posting —
        // it is kept verbatim on the posting above it, or on the transaction
        // itself when it comes before the first posting.
        var rawPostings: [RawPosting] = []
        var leadingComments: [String] = []
        var index = start + 1
        while index < lines.count {
            let currentLine = lines[index]
            if currentLine.isEmpty || currentLine.trimmingCharacters(in: .whitespaces).isEmpty {
                break // blank line ends the transaction
            }
            let first = currentLine.unicodeScalars.first
            guard first == " " || first == "\t" else { break }
            if isTransactionComment(currentLine) {
                if rawPostings.isEmpty {
                    leadingComments.append(currentLine)
                } else {
                    rawPostings[rawPostings.count - 1].trailingComments.append(currentLine)
                }
            } else {
                try rawPostings.append(parsePosting(currentLine, lineNumber: index + 1, into: &formats))
            }
            index += 1
        }

        let postings = try resolveElisions(rawPostings)
        let transaction = try Transaction(
            date: header.date,
            auxDate: header.auxDate,
            status: header.status,
            code: header.code,
            description: header.description,
            postings: postings,
            comment: header.comment,
            leadingComments: leadingComments,
        )
        // Keep the lines this came from, so that a transaction nobody edits is
        // written back exactly as the user wrote it.
        let source = lines[start ..< index].joined(separator: "\n")
        return (transaction.taggedWithSource(source), index - start)
    }

    // MARK: - Header parsing

    private func parseHeader(
        _ line: String,
        lineNumber: Int,
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
                code = String(rest[rest.index(after: rest.startIndex) ..< closeIdx])
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
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
    }

    // MARK: - Posting parsing

    private struct RawPosting {
        var accountName: String
        var amount: Amount?
        var price: PostingPrice?
        var balanceAssertion: Amount?
        var status: ClearingStatus?
        var comment: String?
        /// Full-line comments written below this posting, verbatim.
        var trailingComments: [String] = []
    }

    private func parsePosting(
        _ line: String,
        lineNumber: Int,
        into formats: inout CommodityFormatCollector,
    ) throws -> RawPosting {
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

        // The amount may be trailed by a price and/or a balance assertion.
        // An empty part is dropped rather than parsed: a dangling `@` is not
        // an amount, and refusing to load the file over one would be the very
        // failure this splitting exists to remove.
        var amount: Amount?
        var price: PostingPrice?
        var balanceAssertion: Amount?
        if let rawAmount = amountStr {
            let field = splitAmountField(rawAmount)
            if !field.amount.isEmpty {
                let parsed = try parseAmount(field.amount, lineNumber: lineNumber)
                formats.observe(field.amount, as: parsed)
                amount = parsed
            }
            if let rawPrice = field.price, !rawPrice.isEmpty {
                let priced = try parseAmount(rawPrice, lineNumber: lineNumber)
                formats.observe(rawPrice, as: priced)
                price = field.priceIsTotal ? .total(priced) : .perUnit(priced)
            }
            if let rawAssertion = field.assertion, !rawAssertion.isEmpty {
                let asserted = try parseAmount(rawAssertion, lineNumber: lineNumber)
                formats.observe(rawAssertion, as: asserted)
                balanceAssertion = asserted
            }
        }

        return RawPosting(
            accountName: accountName,
            amount: amount,
            price: price,
            balanceAssertion: balanceAssertion,
            status: postingStatus,
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
    }

    // MARK: - Elision resolution

    private func resolveElisions(_ rawPostings: [RawPosting]) throws -> [Posting] {
        let elidedCount = rawPostings.count(where: { $0.amount == nil })
        guard elidedCount <= 1 else { throw LedgerError.multipleElidedPostings }

        if elidedCount == 0 {
            return try rawPostings.map { raw in
                guard let amount = raw.amount else { throw LedgerError.cannotResolveElision }
                return Self.posting(from: raw, amount: amount)
            }
        }

        // Exactly one elided posting: compute its amount. A priced posting
        // contributes what it cost, not what it moved, so that a share
        // purchase can balance an elided cash leg.
        let explicitAmounts = rawPostings.compactMap { raw in
            raw.amount.map { raw.price?.cost(of: $0.quantity) ?? $0 }
        }
        let commodities = Set(explicitAmounts.map(\.commodity))
        guard commodities.count == 1,
              let commodity = commodities.first,
              let firstAmount = explicitAmounts.first else { throw LedgerError.cannotResolveElision }

        let isPrefix = firstAmount.commodityIsPrefix
        let sum = explicitAmounts.reduce(Decimal.zero) { $0 + $1.quantity }
        let elidedAmount = Amount(quantity: -sum, commodity: commodity, commodityIsPrefix: isPrefix)

        return rawPostings.map { raw in
            Self.posting(from: raw, amount: raw.amount ?? elidedAmount)
        }
    }

    private static func posting(from raw: RawPosting, amount: Amount) -> Posting {
        Posting(
            accountName: raw.accountName,
            amount: amount,
            price: raw.price,
            balanceAssertion: raw.balanceAssertion,
            status: raw.status,
            comment: raw.comment,
            trailingComments: raw.trailingComments,
        )
    }
}
