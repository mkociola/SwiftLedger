import Foundation

/// Errors thrown by the SwiftLedger library.
public enum LedgerError: Error, Sendable, Equatable {
    // MARK: - Parsing

    case parseError(line: Int, message: String)
    case invalidDate(String)
    case invalidAmount(String)
    case multipleElidedPostings
    /// An elided amount has nothing to balance against. An elided posting
    /// spanning several commodities is not this error: it absorbs the
    /// remainder of each one.
    case cannotResolveElision

    // MARK: - Transaction

    case unbalancedTransaction(commodity: String, imbalance: Decimal)
    /// The bracketed (balanced virtual) postings of a transaction do not sum
    /// to zero among themselves. Real postings are checked separately and
    /// report `unbalancedTransaction`; parenthesised postings are never
    /// checked at all.
    case unbalancedBracketedPostings(commodity: String, imbalance: Decimal)
    /// A real posting is named a matched pair of parentheses or brackets
    /// (`(old)`, `[Reserved]`). A real posting's name is written bare, so the
    /// line would be the line a virtual posting writes and the next parse
    /// would read the name back as virtual, leaving the real group short and
    /// the whole file unloadable. Virtual and balanced virtual postings are
    /// unaffected: their delimiters are added on top of whatever the name is.
    case unwritableAccountName(String)

    /// A field a journal has to write on one line contains a line break. The
    /// associated value is the path of the field on the transaction, spelled
    /// the way a caller reaches it: `"description"`, `"code"`, `"comment"`,
    /// `"leadingComments[0]"`, `"postings[1].accountName"`,
    /// `"postings[1].comment"`, `"postings[1].trailingComments[2]"`.
    ///
    /// `JournalSerializer` writes every one of those values verbatim, so a
    /// break inside one puts the rest of the value on a line of its own, where
    /// the next parse reads it as something else: a directive under the
    /// header, a lone elided posting in the body. A dated line with no
    /// postings being a valid entry, nothing downstream objects, and the
    /// amounts that followed the broken line stop counting without a word.
    ///
    /// The parser takes the line ending off a transaction's lines before it
    /// reads a field out of them, so a file with Unix or with Windows endings
    /// never hands one of these back. A `\r` anywhere else on a line is not a
    /// line ending, and the file refuses to load with this same error naming
    /// the field it landed in, rather than being mended into text nobody
    /// wrote. Everything else that reaches here is a transaction built in
    /// code: a caller who forgot to strip the newlines out of pasted input
    /// hears about it from the entry it typed, instead of from a file that
    /// quietly stopped saying what it used to.
    case lineBreakInField(String)

    // MARK: - Commodity

    case commodityMismatch(String, String)

    // MARK: - Store

    case storeError(String)
}

extension LedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .parseError(line, msg):
            "Parse error on line \(line): \(msg)"
        case let .invalidDate(string):
            "Invalid date: '\(string)'"
        case let .invalidAmount(string):
            "Invalid amount: '\(string)'"
        case .multipleElidedPostings:
            "A transaction may have at most one posting with an elided amount"
        case .cannotResolveElision:
            "Cannot resolve elided amount: no explicit amount to balance it against"
        case let .unbalancedTransaction(commodity, imbalance):
            "Transaction is unbalanced in \(commodity): off by \(imbalance)"
        case let .unbalancedBracketedPostings(commodity, imbalance):
            "Balanced virtual postings are off by \(imbalance) in \(commodity)"
        case let .unwritableAccountName(name):
            "Account name '\(name)' cannot be written: a real posting's name may not be "
                + "a matched pair of parentheses or brackets"
        case let .lineBreakInField(field):
            "Field '\(field)' contains a line break and cannot be written on one line"
        case let .commodityMismatch(first, second):
            "Commodity mismatch: '\(first)' vs '\(second)'"
        case let .storeError(msg):
            "Store error: \(msg)"
        }
    }
}
