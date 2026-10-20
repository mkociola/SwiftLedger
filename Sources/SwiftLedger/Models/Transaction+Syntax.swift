// MARK: - Fields the grammar would read back as syntax

import Foundation

extension Transaction {
    /// Refuses a header field the header grammar would read as something
    /// other than the field.
    ///
    /// `JournalSerializer` writes the header as `DATE[=AUX] [*|!] [(CODE)]
    /// DESCRIPTION[  ; COMMENT]`, each field verbatim, and `JournalParser`
    /// reads it back by position, as hledger does: `=` straight after the
    /// date opens a secondary date; `*` or `!` where the status would be is
    /// the status; `(` where the code would be opens a code that runs to the
    /// first `)`, wherever on the line that is, and with no `)` on the line
    /// the parser refuses it; past the code, the first `;` opens the inline
    /// comment, however few spaces precede it; the rest, trimmed, is the
    /// description.
    /// A value that looks like the syntax in front of it is read as that
    /// syntax, and the entry comes back as a different entry, with nothing
    /// downstream to object, or the file SwiftLedger itself has just written
    /// refuses to load at the date.
    ///
    /// The rules are stated exactly as the parser applies them, so that what
    /// the serializer writes in front of a value is what decides whether the
    /// value is safe: a cleared entry described `* Lunch` is written
    /// `* * Lunch` and reads back as itself, and `(CHQ) (note) lunch` is a
    /// code and a description. The description and the comment are refused
    /// with whitespace at either end rather than trimmed here, so that the
    /// caller is told and what is stored is what a reload returns; the parser
    /// does not trim a code, so a code may keep its spaces.
    ///
    /// The parser cannot hand `init` one of these: a code it read stopped at
    /// the first `)`, a description it read stopped at the first `;`, a
    /// marker it read went into the status or the date, and every field it
    /// read was trimmed. A code may hold a `;`, since it is read before the
    /// comment is looked for.
    static func validateHeaderSyntax(
        auxDate: JournalDate?,
        status: ClearingStatus,
        code: String?,
        description: String,
        comment: String?,
    ) throws {
        try requireTrimmed(description, at: "description")
        try requireTrimmed(comment, at: "comment")
        try require(!description.contains(";"), at: "description", rule: "';' opens the inline comment")
        if let code {
            try require(!code.contains(")"), at: "code", rule: "a code runs to the first ')'")
            return
        }
        try require(
            !description.hasPrefix("("), at: "description",
            rule: "with no code in front of it, a description may not open with '(', which opens a code",
        )
        guard status == .unmarked else { return }
        try require(
            !description.hasPrefix("*") && !description.hasPrefix("!"), at: "description",
            rule: "with no status and no code in front of it, a description may not open with '*' or '!', "
                + "which mark a status",
        )
        guard auxDate == nil else { return }
        try require(
            !description.hasPrefix("="), at: "description",
            rule: "with nothing in front of it, a description may not open with '=', "
                + "which introduces a secondary date",
        )
    }

    /// Refuses a posting field the posting grammar would read as something
    /// other than the field, by the same reasoning as `validateHeaderSyntax`.
    ///
    /// A posting is written `[*|! ]NAME  AMOUNT[  ; COMMENT]`, with a virtual
    /// name inside its delimiters, and read back by position: `* ` or `! ` at
    /// the front is the status, the name runs to the first run of two spaces
    /// or tabs and is trimmed, the rest is the amount and, from the first
    /// `;`, the comment. A real posting with no status of its own is written
    /// bare and two spaces follow its name, so a name of `*` alone reads as
    /// a status too; and a line inside an entry that opens with `;` or `#`
    /// is a comment line before it is anything else, so a bare name opening
    /// with either is not a posting at all and the amount on it stops
    /// counting. A virtual posting's delimiters go in front of its name, so
    /// there each marker is content. An empty name leaves the amount to be
    /// read as the name. A run of two spaces or tabs ends a name of any kind,
    /// and a single tab is content, as it is to the parser.
    ///
    /// A file hands the parser none of these, with one corner. The parser
    /// takes `*` or `!` for a status only when a space follows it, so a
    /// posting line that is the marker alone, or the marker with a tab
    /// straight after it and a second space or tab after that, names the
    /// account `*` or `!`. That name cannot be written back, so such a file
    /// refuses to load with the name reported. hledger reads the marker as a
    /// status on both lines and never as a name, so refusing them is the
    /// lesser divergence.
    static func validatePostingSyntax(_ postings: [Posting]) throws {
        for (index, posting) in postings.enumerated() {
            let field = { "postings[\(index)].accountName" }
            let name = posting.accountName
            try requireTrimmed(name, at: field())
            try require(!name.isEmpty, at: field(), rule: "an account name may not be empty")
            try require(
                !containsWhitespaceRun(name), at: field(),
                rule: "two spaces or tabs in a row end an account name",
            )
            if posting.kind == .real, (posting.status ?? .unmarked) == .unmarked {
                try require(
                    name != "*" && name != "!" && !name.hasPrefix("* ") && !name.hasPrefix("! "), at: field(),
                    rule: "with no status of its own, a real posting's name may not be '*' or '!' "
                        + "or open with '* ' or '! ', which mark a status",
                )
                try require(
                    !name.hasPrefix(";") && !name.hasPrefix("#"), at: field(),
                    rule: "with no status of its own, a real posting's name may not open with ';' or '#', "
                        + "which mark a comment line",
                )
            }
            try requireTrimmed(posting.comment, at: "postings[\(index)].comment")
        }
    }

    /// Refuses a commodity the amount grammar would read as something other
    /// than the commodity, by the same reasoning as `validateHeaderSyntax`.
    ///
    /// `JournalSerializer` writes a symbol bare when the amount grammar reads
    /// it back whole, and in double quotes otherwise
    /// (`JournalParser.written(symbol:)`), as hledger writes one that holds a
    /// space, a digit or punctuation; a price and a balance assertion are
    /// written the same way after `@` and `=`. Between the quotes a symbol
    /// may hold anything but two characters: the quote itself, which ends the
    /// symbol early, and `;`, which the posting grammar reads as opening the
    /// comment before it looks for the quotes, as hledger reads it. Either
    /// would come back from the next parse as a different commodity, or
    /// refuse to load at the posting, and nothing about the entry the caller
    /// built is wrong until it is written. An empty symbol is an amount in
    /// no commodity, which the parser reads from a bare number and the
    /// serializer writes back as one; below a `D` line the file puts such a
    /// number in the commodity the line names, as it does every bare number,
    /// which is the file's rule rather than a fault in the value.
    ///
    /// The parser cannot hand `init` one of these: a symbol it read in quotes
    /// stopped at the first quote, and a bare one at the first `;`.
    static func validateCommoditySyntax(_ postings: [Posting]) throws {
        for (index, posting) in postings.enumerated() {
            try requireReadable(posting.amount, at: "postings[\(index)].amount.commodity")
            try requireReadable(posting.price?.amount, at: "postings[\(index)].price.amount.commodity")
            try requireReadable(posting.balanceAssertion, at: "postings[\(index)].balanceAssertion.commodity")
        }
    }

    /// Refuses `amount`'s commodity unless the amount grammar reads it back as
    /// itself, bare or in the quotes the serializer writes for it. A `nil`
    /// amount is a field nothing writes.
    private static func requireReadable(_ amount: Amount?, at field: @autoclosure () -> String) throws {
        guard let symbol = amount?.commodity else { return }
        try require(
            !symbol.contains { $0 == "\"" || $0 == ";" }, at: field(),
            rule: "a '\"' ends a quoted commodity and a ';' opens the comment before the quotes are read, "
                + "so neither can be written in a commodity",
        )
    }

    /// Refuses an `account` directive's name or comment the directive grammar
    /// would read as something other than the field, by the same reasoning as
    /// `validateHeaderSyntax`.
    ///
    /// A directive is written `account NAME[  ; COMMENT]` and read back by
    /// position: the comment opens at the first `;` with two spaces or tabs
    /// in front of it, and the name and the comment are both trimmed. A name
    /// holding that marker comes back cut at it, with the rest as the
    /// comment; a name holding any other run of two spaces or tabs is one
    /// hledger stops reading at, and then refuses the line over, and the one
    /// check on a run refuses both, since the marker opens with one; and an empty
    /// name leaves `account` alone on the line, which the parser keeps as a
    /// line it does not model. The comment runs to the end of the line, so
    /// only its ends matter. Each of these would otherwise come back as a
    /// different directive, or as none, and `Journal.accountDirective(named:)`
    /// would miss the name the caller used.
    ///
    /// The parser cannot hand `init` a marker, an empty name or a value it
    /// would trim. It can hand it a name holding another run, and the file is
    /// then refused at that line, as hledger refuses it.
    static func validateAccountDirectiveSyntax(name: String, comment: String?) throws {
        try requireTrimmed(name, at: "name")
        try require(!name.isEmpty, at: "name", rule: "an account name may not be empty")
        try require(
            !containsWhitespaceRun(name), at: "name",
            rule: "two spaces or tabs in a row end an account name",
        )
        try requireTrimmed(comment, at: "comment")
    }

    /// Every way two spaces or tabs can stand side by side. A run of two or
    /// more holds one of these. The list is built once: plain substring
    /// searches rather than a regex, and no string built per call, because
    /// this runs on every posting of every entry a file parses.
    private static let whitespacePairs = ["  ", " \t", "\t ", "\t\t"]

    /// Whether `value` holds two spaces or tabs in a row, which is what ends
    /// an account name.
    private static func containsWhitespaceRun(_ value: String) -> Bool {
        whitespacePairs.contains { value.contains($0) }
    }

    /// Throws `LedgerError.syntaxInField(field, rule:)` unless `holds`. The
    /// field path and the rule are spelled out only when the rule is broken:
    /// these run on every entry a file parses, and the passing path should
    /// not pay to build either.
    private static func require(
        _ holds: Bool, at field: @autoclosure () -> String, rule: @autoclosure () -> String,
    ) throws {
        guard holds else { throw LedgerError.syntaxInField(field(), rule: rule()) }
    }

    /// What the parser trims from either end of a field, held once so that
    /// asking about a value builds nothing.
    private static let trimmed = CharacterSet.whitespaces

    /// Refuses a value the parser would trim, so that what is stored is what
    /// a reload returns. The character set is the parser's own, and it is
    /// asked about the two ends alone, which is all trimming looks at, rather
    /// than building a trimmed copy to compare. A `nil` value is a field
    /// nothing writes, and an empty one has no ends.
    private static func requireTrimmed(_ value: String?, at field: @autoclosure () -> String) throws {
        guard let first = value?.unicodeScalars.first, let last = value?.unicodeScalars.last else { return }
        try require(
            !trimmed.contains(first) && !trimmed.contains(last), at: field(),
            rule: "the parser trims whitespace from either end, so the value may carry none",
        )
    }
}
