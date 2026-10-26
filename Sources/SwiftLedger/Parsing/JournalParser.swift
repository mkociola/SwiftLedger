import Foundation

/// Parses a plain-text `.ledger` / `.journal` file into a `Journal` value.
///
/// Supported grammar:
/// ```
/// DATE[=AUXDATE] [* | !] [(CODE)] DESCRIPTION [  ; comment]
///     [* | !] ACCOUNT_NAME  [AMOUNT] [  ; comment]
///     [* | !] (ACCOUNT_NAME)  [AMOUNT] [  ; comment]      ; virtual
///     [* | !] [ACCOUNT_NAME]  [AMOUNT] [  ; comment]      ; balanced virtual
/// ```
///
/// - Date formats: year, month and day with one `-`, `/` or `.` between
///   them, leading zeros optional, or month and day alone in the
///   year a `Y` or `year` line sets (see `consumeDates`)
/// - Amount formats: `$100`, `-$50`, `$-50`, `100 USD`, `100.00 EUR`, `£500`.
///   The number is ASCII digits, at most one decimal mark and any number of
///   digit-group marks, and nothing else: `$1e5`, `$0x10`, `$1_000`, `$1x2y`
///   and `1 000 EUR` are `LedgerError.invalidAmount` rather than the 100000,
///   0, 1, 1 and 1 that keeping the longest numeric prefix would make of them.
///   Digits followed by letters still name a commodity, as `10AAPL` does in
///   both tools, but an unquoted commodity symbol carries no digit of its own
///   there or here, so a bare `1e5` is invalid too rather than one unit of a
///   commodity called `e5`. A symbol holding a space, a digit or punctuation
///   is written in double quotes, which are no part of the name: `10 "AAPL
///   2"` is ten units of `AAPL 2`, as it is in hledger, and a rebuilt amount
///   in it is written with the quotes back on. Written bare, such a symbol
///   is no amount here either: `100 E R` and `E*R100` refuse the file, as
///   they do in hledger (`isBareSymbol`).
/// - Decimal marks: both marks are written `.` or `,` depending on where the
///   file comes from, so which is which is read out of the number, as hledger
///   reads it. Two different marks make the last one the decimal mark, so
///   `1,000.00` and `1.000,00` are both a thousand; one mark written more than
///   once groups, so `1.000.000` is a million. A lone mark is read by the
///   file's directives where it has any, as hledger reads them: from the line
///   it stands on, a `commodity`, `D` or `decimal-mark` directive declares
///   the decimal mark for every amount in the commodity it names (every
///   commodity, for `decimal-mark` and for `D`), and a lone mark below it
///   divides when it is the declared one and groups otherwise, whatever
///   follows it, so under `commodity €1.000,00` both `€1.000` and `€12.50`
///   are whole thousands. Without a directive a lone mark divides whatever
///   follows it, as hledger reads it, so `€12,50` is twelve fifty, `€0,750`
///   three quarters and `$1,000` one dollar; ledger-cli would read the last
///   as a thousand, and a file written for it says so with a `commodity` or
///   `decimal-mark` line.
/// - A posting amount may be followed by a price (`@` per unit, `@@` total)
///   and/or a balance assertion (`=`, `==`, `=*` or `==*`), in that order,
///   each written in either commodity style: `10 AAPL @ $150.00 = 30 AAPL`.
///   Prices take part in balancing; assertions are preserved, and checked
///   only when `Ledger.checkBalanceAssertions()` is asked. An assertion with
///   no amount in front of it is a balance assignment, as it is in hledger:
///   the posting takes whatever brings the account to the asserted balance,
///   counted the way the assertion would be checked, over every entry dated
///   before it in every file (`finish(_:)`); what each operator clears
///   besides is described on `assigned(_:operator:to:in:)`.
/// - Status: `*` = cleared, `!` = pending
/// - Code: `(CODE)` after the status, running to the first `)` wherever on
///   the line that is, as hledger reads it. A `(` there with no `)` after it
///   on the line refuses the file, as hledger refuses it: `(CHQ1 Rent` is a
///   typo, not a payee.
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
/// - `alias OLD = NEW`, `alias /PATTERN/ = NEW`, `end aliases`, `apply account
///   NAME` and `end apply account` decide the account a posting or an
///   `account` line below them is booked under, as hledger reads them
///   (`AccountNameRewrites`), and the name the line wrote is kept beside it
///   (`Posting.writtenAccountName`) for a rebuilt entry to write back.
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
/// - A posting's comments can date it: a `date:` or `date2:` tag, or a
///   `[date=date2]` bracket, sets `Posting.date` or `Posting.date2`, read by
///   `Posting.writtenDates`, and the comment is kept as written. Every
///   posting a split elided line becomes is dated as the line is.
/// - Blank lines and full-line comments are preserved in the AST. A line
///   holding nothing but spaces or tabs is blank wherever a blank line
///   matters, so it ends the entry above it, and is kept verbatim as a
///   `.directive`, because `.blank` has nowhere to keep the whitespace and
///   the line has to go back as it came.
/// - Every parsed transaction keeps its own source lines verbatim
///   (`Transaction.sourceText`), so serialising a journal nobody edited
///   reproduces the file byte for byte.
/// - A file with Windows line endings is read as though it had Unix ones.
///   `parse` splits on `\n` and takes the `\r` that closed a line off it
///   before anything reads the line, so that `\r` is the line ending rather
///   than part of what stands in front of it: a description, an account name
///   or a comment that runs to the end of its line comes back without it, a
///   blank line is `.blank`, an `account` line declares the name every
///   posting uses, and `comment` and `end comment` open and close a block.
///   Which ending the file uses is layout, kept on the journal
///   (`Journal.lineEnding`) and written back by `JournalSerializer`, so the
///   file still goes back byte for byte. A file that mixes the two endings is
///   read as the one most of its lines use and written back in that one
///   throughout. A `\r` anywhere but the end of a line is not a line ending:
///   in a field or behind an amount it refuses the file, where hledger reads
///   past it, and classic Mac files, ended by `\r` alone, are unsupported.
/// - Indented full-line comments inside a transaction are commentary, not
///   postings: they are preserved verbatim on the posting above them, or on
///   the transaction when they precede the first posting.
///
/// Any line outside this grammar, such as `P`, `commodity`, `alias`, `D`, `year`,
/// an `include` read from text or an indented sub-directive, is kept verbatim as
/// a `.directive` item and written back unchanged by `JournalSerializer`. The
/// parser never reinterprets what it does not understand. A line at the margin
/// that opens with no word hledger reads at all, `foo bar` or `decimal-markx ,`,
/// is refused at its line, as hledger refuses it (`requireKnownDirective`), and
/// so is an indented line with no block above it to belong to, such as a posting
/// a blank line cut off from its entry.
///
/// An error thrown while an entry is being read says where it was found:
/// `LedgerError.inJournal` carries the line, the header of the entry it was
/// found in, and the error itself underneath, so a caller can point at the
/// place and still match on the cause. A bad amount reports the posting's own
/// line, anything about the entry as a whole the line the entry starts on.
public struct JournalParser {
    public init() {}

    // MARK: - Public API

    /// Parses `text` and returns a `Journal`, an `include` line kept verbatim
    /// as a `.directive` (`parse(fileAt:)` follows one).
    public func parse(_ text: String) throws -> Journal {
        try finish(parse(text, in: ParseContext()))
    }

    /// Parses `text` as the file `context` names, under the declarations in
    /// force where an `include` line read it, or as text when it names none,
    /// with the declarations in force at its end, which an includer reads on.
    ///
    /// What comes back is not yet a `Journal`: an entry holding a balance
    /// assignment is finished by `finish(_:)`, once every file is read.
    func parse(_ text: String, in context: ParseContext) throws -> ParsedFile {
        let (lines, lineEnding) = Self.lines(of: text)
        // On the scalars, since `"\r\n"` is one `Character` and not `"\n"`.
        let endsInNewline = text.unicodeScalars.last == "\n"
        var items: [ParsedItem] = []
        // Watches how the file writes each commodity, so that a transaction
        // the caller later rebuilds is written the same way.
        var style = context.style
        // The year the last `Y` or `year` line set, for a date that leaves it out.
        var year = context.year
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Blank line. One holding spaces or tabs reads as blank too, and
            // is kept as it came so that it is written back as it came.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(.item(line.isEmpty ? .blank : .directive(line)))
                index += 1
                continue
            }

            // A `comment` … `end comment` block: text, not data. Nothing inside
            // it is interpreted, not even the display style a commented-out `D`
            // line would otherwise teach the style collector.
            if isCommentBlockStart(line) {
                let block = try parseCommentBlock(lines: lines, from: index, fileEndsInNewline: endsInNewline)
                items.append(contentsOf: block.map(ParsedItem.item))
                index += block.count // one item per line consumed
                continue
            }

            // Full-line comment — stored verbatim so indentation survives a round-trip.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isFullLineComment(trimmed) {
                items.append(.item(.comment(line)))
                index += 1
                continue
            }

            // account directive. A nameless `account` line is not one we can
            // model, and falls through to be kept verbatim, and so does an
            // indented one, which is a subdirective of the block above it or
            // belongs to nothing (issue #118); the last branch settles which.
            let directive = try located(line: index + 1, entry: nil) { try parseAccountDirective(line, in: style) }
            if let directive {
                items.append(.item(.accountDirective(directive)))
                index += 1
                continue
            }

            // Transaction header: a date at the margin. Indented, a dated line
            // is a subdirective or an orphan, like an `account` line.
            if startsWithDate(line) {
                let (entry, consumed) = try located(line: index + 1, entry: Self.entryHeader(line)) {
                    try parseTransaction(lines: lines, from: index, year: year, into: &style)
                }
                items.append(entry)
                index += consumed
                continue
            }

            // Anything else, an unsupported directive (`include`, `P`, `commodity`,
            // `alias`, `D`, `year`, an indented sub-directive), is kept verbatim,
            // so serialising never rewrites what we cannot interpret. A line
            // at the margin opening with no word hledger reads is refused at
            // its line instead, as hledger refuses it (`requireKnownDirective`).
            // A `D`, `commodity`, `decimal-mark`, `Y`, `year`, `alias` or
            // `apply account` line is read for what it declares and kept
            // verbatim all the same: learning from a line is not the same as
            // modelling it, and this one still goes back byte for byte.
            // One it recognises and cannot read refuses the file at its line,
            // and so does an indented line no block above it can own
            // (`declare(at:in:into:year:)`). In a file, an `include` line
            // reads the files it names (`unmodelledItem`).
            try items.append(located(line: index + 1, entry: nil) {
                try unmodelledItem(at: index, in: lines, style: &style, year: &year, context: context)
            })
            index += 1
        }

        return ParsedFile(items: items, style: style, lineEnding: lineEnding, file: context.file)
    }

    // MARK: - account directives

    /// Reads an `account NAME` line, with its inline comment split off so the
    /// comment text never becomes part of the declared account name.
    ///
    /// Returns `nil` when the line is not an `account` directive, names no
    /// account at all, or is indented: hledger reads an indented `account`
    /// line as a subdirective under an `account` or `commodity` block and
    /// refuses it outside every block, where the parser used to declare the
    /// account wherever the line stood (issue #118).
    ///
    /// The line arrives without its line ending, as every line does. Left on
    /// in a CRLF file, the `\r` would land in the name, or in the comment when
    /// there is one, and `Ledger.accounts` would list the declared account
    /// twice, the second time with nothing posted to it. A `\r` anywhere else
    /// on the line is not a line ending, and the name or comment it lands in
    /// is one no journal can write, so `AccountDirective.init` refuses it and
    /// the file does not load, as it does not for a transaction's field.
    ///
    /// The account is declared under the name the `alias` and `apply
    /// account` lines in force give it, as hledger declares it, and the name
    /// the line wrote is kept for the serializer (`AccountNameRewrites`).
    private func parseAccountDirective(_ line: String, in style: JournalStyleCollector) throws -> AccountDirective? {
        guard line.lowercased().hasPrefix("account ") else { return nil }
        let (mainPart, comment) = splitInlineComment(line)
        let name = String(mainPart.dropFirst("account ".count)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var directive = try AccountDirective(
            name: style.accountNames.booked(name),
            comment: comment?.trimmingCharacters(in: .whitespaces),
        )
        directive.writtenName = directive.name == name ? nil : name
        return directive
    }

    // MARK: - Transaction parsing

    struct ParsedHeader {
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
        year: Int?,
        into style: inout JournalStyleCollector,
    ) throws -> (ParsedItem, Int) {
        let headerLine = lines[start]
        let lineNumber = start + 1 // 1-based for errors
        let entry = Self.entryHeader(headerLine)

        let header = try parseHeader(headerLine, year: year, lineNumber: lineNumber)

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
                let posting = try located(line: index + 1, entry: entry) {
                    try parsePosting(currentLine, lineNumber: index + 1, into: &style)
                }
                rawPostings.append(posting.booked(by: style.accountNames))
            }
            index += 1
        }

        for raw in rawPostings {
            try requireUndatedAssignment(raw, year: header.date.year, entry: entry)
        }
        let raw = RawEntry(
            header: header,
            rawPostings: rawPostings,
            leadingComments: leadingComments,
            source: lines[start ..< index].joined(separator: "\n"),
            lineNumber: lineNumber,
            headerLine: entry,
        )
        // An entry with a balance assignment is finished by `finish(_:)`,
        // once every entry its assignment depends on has been read.
        guard rawPostings.contains(where: Self.isAssignment) else {
            return try (.item(.transaction(transaction(of: raw))), index - start)
        }
        return (.entry(raw), index - start)
    }
}
