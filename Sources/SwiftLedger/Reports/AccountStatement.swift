import Foundation

/// An account statement: a chronological list of transactions affecting one
/// account, with a running balance per commodity.
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
        var prefixFlags: [String: Bool]  = [:]
        var resultLines: [Line]          = []

        let txs = ledger.journal.transactions
            .filter {
                if let fromDate = from, $0.date < fromDate { return false }
                if let toDate = to, $0.date > toDate { return false }
                return $0.postings.contains { $0.accountName == accountName }
            }

        for transaction in txs {
            for posting in transaction.postings where posting.accountName == accountName {
                let commodity = posting.amount.commodity
                balances[commodity, default: .zero] += posting.amount.quantity
                prefixFlags[commodity] = posting.amount.commodityIsPrefix

                let runningBalance = balances.map { (commodity, qty) in
                    Amount(quantity: qty, commodity: commodity, commodityIsPrefix: prefixFlags[commodity] ?? false)
                }.sorted { $0.commodity < $1.commodity }

                resultLines.append(Line(transaction: transaction, posting: posting, runningBalance: runningBalance))
            }
        }

        self.lines = resultLines
    }
}
