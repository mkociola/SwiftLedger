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
        case let .commodityMismatch(first, second):
            "Commodity mismatch: '\(first)' vs '\(second)'"
        case let .storeError(msg):
            "Store error: \(msg)"
        }
    }
}
