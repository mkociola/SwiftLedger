import Foundation

/// An account statement: a chronological list of the postings to one account,
/// with a running balance per commodity.
///
/// Lines are ordered by the postings' own dates, `Posting.date` or else their
/// transaction's, ties broken by original document order, which is what makes
/// each `runningBalance` the account's balance as of that posting. `from` and
/// `to` bound the same dates, as an hledger register does.
public struct AccountStatement: Sendable {
    public struct Line: Sendable {
        public let transaction: Transaction
        public let posting: Posting
        /// Running balance after this posting, per commodity.
        public let runningBalance: [Amount]
    }

    public let accountName: String
    public let lines: [Line]

    // swiftlint:disable:next identifier_name
    public init(ledger: Ledger, accountName: String, from: JournalDate? = nil, to: JournalDate? = nil) {
        self.accountName = accountName

        var balances: [String: Decimal] = [:]
        var prefixFlags: [String: Bool] = [:]
        var resultLines: [Line] = []

        // Date-ordered by `Ledger`, unlike `journal.transactions`, which is in
        // document order. The running balance accumulated below is only
        // correct chronologically.
        for (transaction, index) in ledger.postingsByDate(from: from, to: to) {
            let posting = transaction.postings[index]
            guard posting.accountName == accountName else { continue }
            let commodity = posting.amount.commodity
            balances[commodity, default: .zero] += posting.amount.quantity
            prefixFlags[commodity] = posting.amount.commodityIsPrefix

            let runningBalance = balances.map { commodity, qty in
                Amount(quantity: qty, commodity: commodity, commodityIsPrefix: prefixFlags[commodity] ?? false)
            }.sorted { $0.commodity < $1.commodity }

            resultLines.append(Line(transaction: transaction, posting: posting, runningBalance: runningBalance))
        }

        lines = resultLines
    }
}
