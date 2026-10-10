// MARK: - Fields the grammar would read back as syntax

import Foundation

extension Transaction {
    /// Refuses a header field the header grammar would read as something
    /// other than the field.
    ///
    /// `JournalSerializer` writes the header as `DATE[=AUX] [*|!] [(CODE)]
    /// DESCRIPTION[  ; COMMENT]`, each field verbatim, and `JournalParser`
    /// reads it back by position: the inline comment opens at the first `;`
    /// with two spaces or tabs in front of it, wherever on the line that is;
    /// `=` straight after the date opens a secondary date; `*` or `!` where
    /// the status would be is the status; `(` where the code would be opens a
    /// code that runs to the first `)`; the rest, trimmed, is the description.
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
    /// the first `)`, a marker it read went into the status or the date, and
    /// every field it read was trimmed.
    static func validateHeaderSyntax(
        auxDate: JournalDate?,
        status: ClearingStatus,
        code: String?,
        description: String,
        comment: String?,
    ) throws {
        try requireTrimmed(description, at: "description")
        try requireTrimmed(comment, at: "comment")
        try requireNoCommentMarker(description, at: "description")
        if let code {
            try requireNoCommentMarker(code, at: "code")
            try require(!code.contains(")"), at: "code", rule: "a code runs to the first ')'")
            return
        }
        try require(
            !(description.hasPrefix("(") && description.contains(")")), at: "description",
            rule: "with no code in front of it, a description may not open with '(' and go on to a ')', "
                + "which is how a code is written",
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
    /// A file hands the parser none of these, with one corner: a posting line
    /// of `*` and two tabs names the account `*`, which cannot be written
    /// back, so such a file refuses to load with the name reported. hledger
    /// reads that line as a status rather than a name, so refusing it is the
    /// lesser divergence.
    static func validatePostingSyntax(_ postings: [Posting]) throws {
        for (index, posting) in postings.enumerated() {
            let field = "postings[\(index)].accountName"
            let name = posting.accountName
            try requireTrimmed(name, at: field)
            try require(!name.isEmpty, at: field, rule: "an account name may not be empty")
            try require(
                !containsWhitespaceRun(name), at: field,
                rule: "two spaces or tabs in a row end an account name",
            )
            if posting.kind == .real, (posting.status ?? .unmarked) == .unmarked {
                try require(
                    name != "*" && name != "!" && !name.hasPrefix("* ") && !name.hasPrefix("! "), at: field,
                    rule: "with no status of its own, a real posting's name may not be '*' or '!' "
                        + "or open with '* ' or '! ', which mark a status",
                )
                try require(
                    !name.hasPrefix(";") && !name.hasPrefix("#"), at: field,
                    rule: "with no status of its own, a real posting's name may not open with ';' or '#', "
                        + "which mark a comment line",
                )
            }
            try requireTrimmed(posting.comment, at: "postings[\(index)].comment")
        }
    }

    /// Every way two spaces or tabs can stand side by side. A run of two or
    /// more holds one of these, and a run followed by `;` ends in one of
    /// `commentOpeners`. Both lists are built once: plain substring searches
    /// rather than a regex, and no string built per call, because this runs
    /// on every posting of every entry a file parses.
    private static let whitespacePairs = ["  ", " \t", "\t ", "\t\t"]
    private static let commentOpeners = whitespacePairs.map { $0 + ";" }

    /// Whether `value` holds two spaces or tabs in a row, which is what ends
    /// an account name.
    private static func containsWhitespaceRun(_ value: String) -> Bool {
        whitespacePairs.contains { value.contains($0) }
    }

    /// Throws `LedgerError.syntaxInField(field, rule:)` unless `holds`. The
    /// rule is spelled out only when it is broken: these run on every entry a
    /// file parses, and the passing path should not pay to build its wording.
    private static func require(_ holds: Bool, at field: String, rule: @autoclosure () -> String) throws {
        guard holds else { throw LedgerError.syntaxInField(field, rule: rule()) }
    }

    /// Refuses a value the parser would trim, so that what is stored is what
    /// a reload returns. The character set is the parser's own. A `nil` value
    /// is a field nothing writes.
    private static func requireTrimmed(_ value: String?, at field: String) throws {
        guard let value else { return }
        try require(
            value == value.trimmingCharacters(in: .whitespaces), at: field,
            rule: "the parser trims whitespace from either end, so the value may carry none",
        )
    }

    /// Refuses a value holding the two spaces or tabs and `;` that open the
    /// inline comment, which the parser looks for across the whole header
    /// line before it reads anything else out of it.
    private static func requireNoCommentMarker(_ value: String, at field: String) throws {
        try require(
            !commentOpeners.contains { value.contains($0) }, at: field,
            rule: "two spaces or tabs followed by ';' open the inline comment",
        )
    }
}
