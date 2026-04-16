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
    case emptyTransaction
    case unbalancedTransaction(commodity: String, imbalance: Decimal)

    // MARK: - Commodity
    case commodityMismatch(String, String)

    // MARK: - Store
    case storeError(String)
}

extension LedgerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .parseError(let line, let msg):
            "Parse error on line \(line): \(msg)"
        case .invalidDate(let string):
            "Invalid date: '\(string)'"
        case .invalidAmount(let string):
            "Invalid amount: '\(string)'"
        case .multipleElidedPostings:
            "A transaction may have at most one posting with an elided amount"
        case .cannotResolveElision:
            "Cannot resolve elided amount: remaining postings span multiple commodities"
        case .emptyTransaction:
            "A transaction must contain at least two postings"
        case .unbalancedTransaction(let commodity, let imbalance):
            "Transaction is unbalanced in \(commodity): off by \(imbalance)"
        case .commodityMismatch(let first, let second):
            "Commodity mismatch: '\(first)' vs '\(second)'"
        case .storeError(let msg):
            "Store error: \(msg)"
        }
    }
}
