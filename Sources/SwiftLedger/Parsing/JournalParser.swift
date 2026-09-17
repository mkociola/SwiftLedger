import Foundation

/// Parses a plain-text `.ledger` / `.journal` file into a `Journal` value.
///
/// Supported grammar:
/// ```
/// DATE [= AUXDATE] [* | !] [(CODE)] DESCRIPTION [  ; comment]
///     [* | !] ACCOUNT_NAME  [AMOUNT] [  ; comment]
///     [* | !] (ACCOUNT_NAME)  [AMOUNT] [  ; comment]      ; virtual
///     [* | !] [ACCOUNT_NAME]  [AMOUNT] [  ; comment]      ; balanced virtual
/// ```
///
/// - Date formats: `YYYY-MM-DD` or `YYYY/MM/DD`
/// - Amount formats: `$100`, `-$50`, `$-50`, `100 USD`, `100.00 EUR`, `£500`.
///   The number is ASCII digits, at most one decimal mark and any number of
///   digit-group marks, and nothing else: `$1e5`, `$0x10`, `$1_000`, `$1x2y`
///   and `1 000 EUR` are `LedgerError.invalidAmount` rather than the 100000,
///   0, 1, 1 and 1 that keeping the longest numeric prefix would make of them.
///   Digits followed by letters still name a commodity, as `10AAPL` does in
///   both tools, but an unquoted commodity symbol carries no digit of its own
///   there or here, so a bare `1e5` is invalid too rather than one unit of a
///   commodity called `e5`. A quoted symbol may carry anything and is kept as
///   written, quotes included: `10 "AAPL 2"`.
/// - Decimal marks: both marks are written `.` or `,` depending on where the
///   file comes from, so which is which is read out of the number, as hledger
///   reads it. Two different marks make the last one the decimal mark, so
///   `1,000.00` and `1.000,00` are both a thousand; one mark written more than
///   once groups, so `1.000.000` is a million; one mark with any count of
///   digits after it other than three divides, so `€12,50` is twelve fifty;
///   and one mark with nothing but zeros in front of it divides whatever
///   follows, since there is nothing there to group, so `€0,750` is three
///   quarters. One mark with exactly three digits after it is the one shape
///   the number cannot settle, and it keeps the reading this library and
///   ledger-cli have always had: `1,000` is a thousand and `1.000` is one,
///   where hledger would read `1,000` as one. A `commodity` or `D` directive
///   is read for the display style it states, never for this.
/// - A posting amount may be followed by a price (`@` per unit, `@@` total)
///   and/or a balance assertion (`=`), in that order, each written in either
///   commodity style: `10 AAPL @ $150.00 = 30 AAPL`. Prices take part in
///   balancing; assertions are preserved but never checked.
/// - Status: `*` = cleared, `!` = pending
/// - Comments: `;`, `#`, `*`, `%` or `|` at line start; inline `  ;` after
///   2+ spaces. On a posting line the two-space rule ends the account name
///   rather than the amount, so once a name has ended, a `;` opens the
///   posting's comment however few spaces come before it: `$66.00 ; an
///   expense` is an amount and a comment, as it is in ledger and hledger. A
///   posting that writes no amount has no field for that to apply to, so its
///   `;` still needs the two spaces.
/// - A `comment` or `test` line at column 0 opens a block comment, anything
///   after the keyword being ignored, and the block runs to the next
///   `end comment` or `end test` line at column 0, or to the end of the file.
///   Everything between the two, the keyword lines included, is kept verbatim
///   and none of it is interpreted: a transaction written there is text, not
///   data.
/// - `account NAME` directives, with an optional inline comment
/// - Virtual postings: `(ACCOUNT)` takes no part in balancing; `[ACCOUNT]` is
///   exempt from balancing against the real postings but the bracketed
///   postings of one transaction must sum to zero among themselves. The
///   delimiters are stripped from `Posting.accountName` and written back for a
///   rebuilt posting, and `Posting ==` includes the kind, so a real posting
///   never compares equal to a virtual one of the same account. Both ends must
///   match with something between them, so an unmatched bracket is part of the
///   name; only the outermost pair is stripped, so `((ACCOUNT))` is the
///   virtual account `(ACCOUNT)`; and space just inside the delimiters is
///   padding, so `( ACCOUNT )` names the same account as `(ACCOUNT)`. A real
///   posting's name may not itself be a matched pair, since it would be
///   written bare and read back virtual: `Transaction.init` refuses one
///   (`LedgerError.unwritableAccountName`).
/// - A transaction may carry any number of postings, none included: a dated
///   line on its own is a valid entry, as it is in ledger and hledger, and so
///   is a single posting of zero. The rule is that every commodity nets to
///   zero in each balancing group, never a posting count.
/// - At most one posting per balancing group may elide its amount, and it
///   takes what the rest of its own group leaves over in every commodity, so
///   an opening-balances entry in dollars and pounds resolves. Since a
///   `Posting` holds one amount, such a line becomes one posting per commodity
///   left to absorb, where the elided line was. An elided parenthesised
///   posting has no group to balance against and reads as zero, which is
///   hledger's reading; ledger-cli would hand it the real remainder instead.
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
        var style = JournalStyleCollector()
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

            // A `comment` … `end comment` block: text, not data. Nothing inside
            // it is interpreted, not even the display style a commented-out `D`
            // line would otherwise teach the style collector.
            if isCommentBlockStart(line) {
                let block = parseCommentBlock(lines: lines, from: index)
                items.append(contentsOf: block)
                index += block.count // one item per line consumed
                continue
            }

            // Full-line comment — stored verbatim so indentation survives a round-trip.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isFullLineComment(trimmed) {
                items.append(.comment(line))
                index += 1
                continue
            }

            // account directive. A nameless `account` line is not one we can
            // model, and falls through to be kept verbatim.
            if let directive = parseAccountDirective(trimmed) {
                items.append(.accountDirective(directive))
                index += 1
                continue
            }

            // Transaction header (starts with a date)
            if startsWithDate(trimmed) {
                let (transaction, consumed) = try parseTransaction(lines: lines, from: index, into: &style)
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
            declareFormat(from: line, into: &style)
            items.append(.directive(line))
            index += 1
        }

        return Journal(
            items: items,
            commodityFormats: style.formats,
            amountAlignment: style.amountAlignment,
            postingIndent: style.postingIndent,
        )
    }

    // MARK: - account directives

    /// Reads an `account NAME` line, with its inline comment split off so the
    /// comment text never becomes part of the declared account name.
    ///
    /// Returns `nil` when the line is not an `account` directive, or names no
    /// account at all.
    private func parseAccountDirective(_ trimmed: String) -> AccountDirective? {
        guard trimmed.lowercased().hasPrefix("account ") else { return nil }
        let (mainPart, comment) = splitInlineComment(trimmed)
        let name = String(mainPart.dropFirst("account ".count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return AccountDirective(
            name: name,
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
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
        into style: inout JournalStyleCollector,
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
                try rawPostings.append(parsePosting(currentLine, lineNumber: index + 1, into: &style))
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

    struct RawPosting {
        var accountName: String
        var kind: Posting.Kind
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
        into style: inout JournalStyleCollector,
    ) throws -> RawPosting {
        var rest = line.trimmingCharacters(in: .whitespaces)

        // Optional status (* or !)
        var postingStatus: ClearingStatus?
        if rest.hasPrefix("* ") || rest.hasPrefix("! ") {
            postingStatus = rest.hasPrefix("*") ? .cleared : .pending
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Account name ends at 2+ spaces, or at end of line. The token is kept
        // as the line writes it for the style observation below; the posting
        // stores the bare name. The comment is split off what follows the
        // name rather than off the whole line, because there the `;` needs no
        // two spaces in front of it, and the field the margin is measured
        // against is the one with the comment already gone.
        let (accountToken, field) = splitAccountAndAmount(rest)
        let (amountStr, comment) = splitPostingComment(field)
        let (accountName, kind) = Posting.Kind.split(accountToken)
        style.observeIndent(String(line.prefix { $0 == " " || $0 == "\t" }))
        if let amountStr, let start = Self.amountColumn(in: line, after: accountToken) {
            style.observeAmountField(start: start, end: start + amountStr.count)
        }

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
                let parsed = try parseShapedAmount(field.amount, lineNumber: lineNumber)
                style.observe(field.amount, shape: parsed.shape, as: parsed.amount)
                amount = parsed.amount
            }
            if let rawPrice = field.price, !rawPrice.isEmpty {
                let priced = try parseShapedAmount(rawPrice, lineNumber: lineNumber)
                style.observe(rawPrice, shape: priced.shape, as: priced.amount)
                price = field.priceIsTotal ? .total(priced.amount) : .perUnit(priced.amount)
            }
            if let rawAssertion = field.assertion, !rawAssertion.isEmpty {
                let asserted = try parseShapedAmount(rawAssertion, lineNumber: lineNumber)
                style.observe(rawAssertion, shape: asserted.shape, as: asserted.amount)
                balanceAssertion = asserted.amount
            }
        }

        return RawPosting(
            accountName: accountName,
            kind: kind,
            amount: amount,
            price: price,
            balanceAssertion: balanceAssertion,
            status: postingStatus,
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
    }
}
