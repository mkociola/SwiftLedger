import Foundation

/// Errors thrown by the SwiftLedger library.
public enum LedgerError: Error, Sendable, Equatable {
    // MARK: - Parsing

    case parseError(line: Int, message: String)
    case invalidDate(String)
    case invalidAmount(String)
    case multipleElidedPostings
    case cannotResolveElision

    // MARK: - Transaction

    case unbalancedTransaction(commodity: String, imbalance: Decimal)
    /// The bracketed (balanced virtual) postings of a transaction do not sum
    /// to zero among themselves. Real postings are checked separately and
    /// report `unbalancedTransaction`; parenthesised postings are never
    /// checked at all.
    case unbalancedBracketedPostings(commodity: String, imbalance: Decimal)

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
            "Cannot resolve elided amount: remaining postings span multiple commodities"
        case let .unbalancedTransaction(commodity, imbalance):
            "Transaction is unbalanced in \(commodity): off by \(imbalance)"
        case let .unbalancedBracketedPostings(commodity, imbalance):
            "Balanced virtual postings are off by \(imbalance) in \(commodity)"
        case let .commodityMismatch(first, second):
            "Commodity mismatch: '\(first)' vs '\(second)'"
        case let .storeError(msg):
            "Store error: \(msg)"
        }
    }
}
