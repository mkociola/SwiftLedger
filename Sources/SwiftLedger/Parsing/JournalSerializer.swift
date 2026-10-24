import Foundation

/// Serialises a `Journal` back to plain-text `.ledger` / `.journal` format.
///
/// Round-trip fidelity goals:
/// - A transaction that came from `JournalParser` and was not changed since is
///   written back from its own source lines, byte for byte. A journal file the
///   caller only read therefore survives a save untouched — no re-alignment, no
///   re-formatted amounts, and a diff that shows only what the user did.
/// - Preserves blank lines, comments, and account directives.
/// - Full-line comments inside a transaction are written back verbatim, in
///   place, from `Transaction.leadingComments` and `Posting.trailingComments`.
/// - Lines the parser does not model (`include`, `P`, `commodity`, `alias`,
///   `D`, `year`, indented sub-directives, …) are written back verbatim, as
///   are the lines of a block comment.
/// - Every line ends the way the file's lines ended (`Journal.lineEnding`),
///   the ones written for a rebuilt entry included, so an edit in a journal
///   kept on Windows does not leave one entry with Unix endings. A journal
///   built in code is written with Unix endings.
///
/// The rules below describe the formatting applied to a transaction the caller
/// built or changed — one with no source lines of its own:
/// - Elided postings (resolved during parsing) are written with explicit
///   amounts. An elided line that absorbed more than one commodity was
///   resolved into one posting per commodity, so it comes back as one line
///   per commodity with the account name repeated, which is how hledger
///   prints such an entry.
/// - Amounts are formatted using the stored `commodityIsPrefix` flag, in the
///   decimal places, decimal and group marks, thousands separators and
///   minus-sign placement the rest of the journal uses for that commodity
///   (`Journal.commodityFormats`). A `Decimal` has forgotten every one of them
///   by the time it gets here, so without that an edit to a payee would also
///   restyle that entry's `$-1,234.50` to `-$1234.5`, and a European file's
///   `€1.500,00` to `€1,500.00`. The decimal mark is the one in force where
///   the entry stands, where a `decimal-mark`, `commodity` or `D` line above
///   it declares one: a file may switch marks part way through, and an
///   eighth written `€1.125` under `decimal-mark ,` reads back as eleven
///   hundred odd (issue #80). A grouped thousand with no fraction is written
///   `1000` rather than the `1,000` or `1.000` that reads back as one in
///   both tools. A commodity symbol that holds a space, a digit or
///   punctuation is written in double quotes, as hledger writes it, since
///   bare it would not read back: `10 "Mutual Fund"`. An amount in no
///   commodity is written as the bare number it was read from.
/// - A posting's price and balance assertion are re-emitted after its amount,
///   in canonical `AMOUNT @ PRICE = ASSERTION` order.
/// - An account is written under the name the journal wrote it under, when
///   the `alias` and `apply account` lines in force still book that name as
///   the account, so a rebuilt entry keeps the file's short names; otherwise
///   under a name they do book as it, the account without the open `apply
///   account` prefix first. An `account` directive is written the same way.
///   See `AccountNameRewrites.spelling(of:written:)`.
/// - A virtual posting's account name is written back inside its own
///   delimiters: `(name)` or `[name]`. The delimiters count toward the margin,
///   so a rebuilt envelope leg lines its amount up with its neighbours.
/// - Postings are indented the way the rest of the journal indents its own
///   (`Journal.postingIndent`), falling back to 4 spaces.
/// - Amount fields are lined up the way the rest of the journal lines its own
///   up (`Journal.amountAlignment`) — beginning at one column, or ending at
///   one — falling back to beginning at column 52, the ledger-cli default, for
///   a journal that shows none.
public struct JournalSerializer {
    public init() {}

    // MARK: - Public API

    /// Serialises the journal to a string: this file's text, an `include`
    /// line written back as it came (`serializedFiles(_:)` writes the files
    /// it read).
    public func serialize(_ journal: Journal) -> String {
        serializedFiles(journal)[0].text
    }

    /// The text of every file in the journal's tree: this journal first,
    /// whatever its `file`, then each included journal that has a `file`,
    /// depth first in document order, a file included twice listed twice.
    ///
    /// An included file is written from the declarations in force at the
    /// `include` line that read it, as the parser read it, so a rebuilt entry
    /// under the including file's `apply account Top` writes `a`, not the
    /// `Top:a` the next parse books as `Top:Top:a`. What the included file
    /// declares stays in it. `edited` is the file's `Journal.edited`, for
    /// the store to tell which included files to write.
    func serializedFiles(_ journal: Journal) -> [SerializedFile] {
        var files: [SerializedFile] = []
        write(journal, from: FileWalk(), into: &files)
        return files
    }

    /// One file's text, for the store and the manager.
    struct SerializedFile {
        var file: URL?
        var text: String
        var edited: Bool
    }

    /// Where the walk over one file stands: the lines written so far, and
    /// the directives in force at that point, read as `JournalParser` reads
    /// them. `Journal.commodityFormats` carries one mark per commodity for
    /// the whole file, and a `decimal-mark`, `commodity` or `D` line speaks
    /// from where it stands to the next one, so a rebuilt entry is written
    /// by the line above it rather than by the file as a whole (issue #80).
    /// They are read through the parser's own `declare(at:in:into:year:)`,
    /// over the lines written so far, so that an indented `format` line
    /// declares a style only where the next parse reads one, under a
    /// `commodity` block. Read wherever it stood, one under an `account`
    /// block gave its commodity a mark the parser does not read it by, and a
    /// rebuilt `4.50 EUR` came back as 450 EUR.
    private struct FileWalk {
        var lines: [String] = []
        var declared = JournalStyleCollector()
        var year: Int?
        var inBlockComment = false
    }

    /// Writes `journal` as one file, starting from the directives `walk`
    /// has in force, and appends its text to `files` ahead of the files it
    /// includes.
    private func write(_ journal: Journal, from start: FileWalk, into files: inout [SerializedFile]) {
        let slot = files.count
        files.append(SerializedFile(file: journal.file, text: "", edited: journal.edited.isSet))
        var walk = start
        walk.lines = []
        walk.inBlockComment = false
        for item in journal.items {
            write(item, of: journal, walk: &walk, files: &files)
        }
        // hledger refuses a file that ends on a block comment's line with no
        // newline after it (issue #66), and an edit can leave one last.
        if journal.endsOnBlockCommentLine { walk.lines.append("") }
        files[slot].text = walk.lines.joined(separator: journal.lineEnding.rawValue)
        // A journal with no file of its own has nowhere to be written. The
        // top one is kept all the same, since the caller names where it goes.
        if slot > 0, journal.file == nil { files.remove(at: slot) }
    }

    private func write(
        _ item: JournalItem, of journal: Journal, walk: inout FileWalk, files: inout [SerializedFile],
    ) {
        switch item {
        case .blank:
            walk.lines.append("")
        case let .comment(text):
            // Line by line, so a break inside the text cannot put a dated
            // line where the next parse books it. A Windows break in
            // the text is a break like any other, so it leaves no `\r` on
            // a line for the journal's own ending to follow. A `\r` that
            // ends the text broke nothing and is written as it came.
            let commentLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            walk.lines.append(contentsOf: commentLines.map { isCommentLine($0) ? $0 : "; \($0)" })
        case let .directive(raw):
            // Verbatim, a `\n` included: a directive has no marker to put
            // in front of a second line, so `LedgerManager` refuses one
            // that holds a `\n` instead (issue #72).
            walk.lines.append(raw)
            declare(raw, in: &walk)
        case let .include(included):
            walk.lines.append(included.line)
            for child in included.journals {
                write(child, from: walk, into: &files)
            }
        case let .accountDirective(directive):
            walk.lines.append(accountLine(directive, declared: walk.declared))
        case let .transaction(transaction):
            walk.lines.append(contentsOf: serializeTransaction(
                transaction,
                formats: journal.commodityFormats,
                declared: walk.declared,
                alignment: journal.amountAlignment ?? Self.defaultAlignment,
                indent: journal.postingIndent ?? Self.defaultIndent,
            ))
        }
    }

    /// Reads what the directive line just written declares into `walk`. A
    /// line inside a `comment` block is text the parser reads nothing from,
    /// and a line it would refuse declares nothing either, since the file it
    /// is in does not load.
    private func declare(_ raw: String, in walk: inout FileWalk) {
        let parser = JournalParser()
        if walk.inBlockComment {
            walk.inBlockComment = !parser.isCommentBlockEnd(raw)
        } else if parser.isCommentBlockStart(raw) {
            walk.inBlockComment = true
        } else {
            try? parser.declare(at: walk.lines.count - 1, in: walk.lines, into: &walk.declared, year: &walk.year)
        }
    }

    /// An `account` line, its name spelled the way the `alias` and `apply
    /// account` lines in force where it stands book it as the account.
    private func accountLine(_ directive: AccountDirective, declared: JournalStyleCollector) -> String {
        let name = declared.accountNames.spelling(of: directive.name, written: directive.writtenName)
        guard let comment = directive.comment else { return "account \(name)" }
        return "account \(name)  ; \(comment)"
    }

    // MARK: - Comments

    /// Whether `text` already reads as a full-line comment and can be written
    /// back untouched.
    ///
    /// Text that does not — a programmatically supplied `.comment("reviewed")`,
    /// say — is given a `; ` marker, so serialising never emits a line the
    /// parser would read back as something other than a comment. A comment
    /// holding a line break is asked line by line, for the same reason.
    private func isCommentLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        // The parser's own list, so that every marker it reads as a comment is
        // one this writes back untouched.
        return JournalParser.fullLineCommentMarkers.contains(first)
    }

    /// Renders one full-line comment belonging to a transaction body.
    ///
    /// A line that already reads as an in-transaction comment — indented, and
    /// marked with `;` or `#` — is written back untouched. Anything else is
    /// indented and given a `; ` marker, so serialising never emits a line the
    /// parser would read back as a posting, a status-marked line, or a
    /// top-level comment outside the transaction.
    private func transactionCommentLine(_ text: String) -> String {
        let isIndented = text.first == " " || text.first == "\t"
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isMarked = trimmed.hasPrefix(";") || trimmed.hasPrefix("#")
        if isIndented, isMarked {
            return text
        }
        return "    " + (isMarked ? trimmed : "; \(trimmed)")
    }

    // MARK: - Transaction serialisation

    /// How amounts are lined up when the journal shows no margin of its own:
    /// beginning at column 52, ledger-cli's default and what SwiftLedger has
    /// always written.
    static let defaultAlignment = AmountAlignment.start(column: 52)

    /// How postings are indented when the journal shows no indent of its own.
    static let defaultIndent = "    "

    private func serializeTransaction(
        _ transaction: Transaction,
        formats: [String: CommodityFormat],
        declared: JournalStyleCollector,
        alignment: AmountAlignment,
        indent: String,
    ) -> [String] {
        // Parsed and untouched: hand back the user's own lines. Formatting them
        // would rewrite the whole file on any edit, which is exactly what a
        // plain-text journal kept in version control cannot afford.
        if let source = transaction.sourceText {
            return source.components(separatedBy: "\n")
        }

        var lines: [String] = []

        // Header line
        var header = transaction.date.description
        if let aux = transaction.auxDate {
            header += "=\(aux.description)"
        }
        if transaction.status != .unmarked {
            header += " \(transaction.status.rawValue)"
        }
        if let code = transaction.code {
            header += " (\(code))"
        }
        header += " \(transaction.description)"
        if let comment = transaction.comment {
            header += "  ; \(comment)"
        }
        lines.append(header)

        // Comment lines written before the first posting
        for comment in transaction.leadingComments {
            lines.append(transactionCommentLine(comment))
        }

        // Posting lines, each followed by the comment lines written below it
        for posting in transaction.postings {
            var line = serializePosting(
                posting, formats: formats, declared: declared, alignment: alignment, indent: indent,
            )
            // A leg of a split elided line may hold a date its own comments
            // do not write, and the next parse reads dates from comments alone.
            if let tags = posting.unwrittenDateTags(year: transaction.date.year) {
                line += (posting.comment.map { $0.isEmpty ? "" : ", " } ?? "  ; ") + tags
            }
            lines.append(line)
            for comment in posting.trailingComments {
                lines.append(transactionCommentLine(comment))
            }
        }

        return lines
    }

    private func serializePosting(
        _ posting: Posting,
        formats: [String: CommodityFormat],
        declared: JournalStyleCollector,
        alignment: AmountAlignment,
        indent: String,
    ) -> String {
        var line = indent

        if let postingStatus = posting.status, postingStatus != .unmarked {
            line += "\(postingStatus.rawValue) "
        }

        let name = declared.accountNames.spelling(of: posting.accountName, written: posting.writtenAccountName)
        line += posting.kind.delimited(name)

        let amountStr = formatPostingAmount(posting, formats: formats, declared: declared)
        // Pad to the journal's own margin — two spaces at minimum, since one
        // is not enough to separate an account name from an amount.
        let padding: Int = switch alignment {
        case let .start(column): column - line.count
        case let .end(column): column - line.count - amountStr.count
        }
        line += String(repeating: " ", count: max(2, padding))
        line += amountStr

        if let comment = posting.comment {
            line += "  ; \(comment)"
        }

        return line
    }

    /// The whole amount field of a posting: the amount, then whatever price
    /// and balance assertion it carries, in the order ledger writes them —
    /// `AMOUNT @ PRICE = ASSERTION`, canonically spaced, with the assertion's
    /// own operator.
    private func formatPostingAmount(
        _ posting: Posting, formats: [String: CommodityFormat], declared: JournalStyleCollector,
    ) -> String {
        let format = { formatAmount($0, formats: formats, declared: declared) }
        var field = format(posting.amount)
        switch posting.price {
        case nil: break
        case let .perUnit(price): field += " @ \(format(price))"
        case let .total(price): field += " @@ \(format(price))"
        }
        if let assertion = posting.balanceAssertion {
            field += " \(posting.balanceAssertionOperator.rawValue) \(format(assertion))"
        }
        return field
    }

    /// Writes one amount in the journal's own style for its commodity, falling
    /// back to `CommodityFormat.default(for:)` for a commodity the file has no
    /// example of — a journal built in code, or the first `$` amount in a file
    /// that has none yet. Either way the decimal mark is the one `declared`
    /// has in force where the entry stands, when a directive above it has
    /// declared one.
    ///
    /// The style sets a minimum number of decimal places, never a maximum, so
    /// an amount carrying more digits than the house style keeps all of them.
    /// Rounding here would change what the journal says and could leave a
    /// transaction that no longer balances.
    private func formatAmount(
        _ amount: Amount, formats: [String: CommodityFormat], declared: JournalStyleCollector,
    ) -> String {
        var format = formats[amount.commodity] ?? .default(for: amount.commodity)
        // The mark is the one the directives in force here read a lone mark
        // by, asked as the parser asks them, with a bare number in no
        // commodity. Where none is in force the file's own mark stands, and
        // reads back right, since a lone mark divides there whichever it is.
        if let mark = declared.declaredDecimalMark(for: amount.commodity.isEmpty ? nil : amount.commodity) {
            format.decimalMark = mark
        }
        let absValue = format.render(abs(amount.quantity))
        let sign = amount.quantity < 0 ? "-" : ""
        // The quotes a symbol may need are no part of its name, which is
        // what the format is keyed by. No name at all is a bare number,
        // which reads back as one, or as the commodity a `D` line above it
        // names, as the number it was read from did.
        let symbol = JournalParser.written(symbol: amount.commodity)
        guard !symbol.isEmpty else { return "\(sign)\(absValue)" }
        guard amount.commodityIsPrefix else {
            return "\(sign)\(absValue) \(symbol)"
        }
        let gap = format.separatesPrefixCommodity ? " " : ""
        return format.signPrecedesCommodity
            ? "\(sign)\(symbol)\(gap)\(absValue)"
            : "\(symbol)\(gap)\(sign)\(absValue)"
    }
}
