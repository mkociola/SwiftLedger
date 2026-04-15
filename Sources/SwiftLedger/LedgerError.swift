import Foundation

/// Errors thrown by the SwiftLedger library.
public enum LedgerError: Error, Sendable {
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
        case .invalidDate(let s):
            "Invalid date: '\(s)'"
        case .invalidAmount(let s):
            "Invalid amount: '\(s)'"
        case .multipleElidedPostings:
            "A transaction may have at most one posting with an elided amount"
        case .cannotResolveElision:
            "Cannot resolve elided amount: remaining postings span multiple commodities"
        case .emptyTransaction:
            "A transaction must contain at least two postings"
        case .unbalancedTransaction(let c, let imbalance):
            "Transaction is unbalanced in \(c): off by \(imbalance)"
        case .commodityMismatch(let a, let b):
            "Commodity mismatch: '\(a)' vs '\(b)'"
        case .storeError(let msg):
            "Store error: \(msg)"
        }
    }
}
