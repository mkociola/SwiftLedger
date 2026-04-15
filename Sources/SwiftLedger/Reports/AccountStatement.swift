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

    public init(ledger: Ledger, accountName: String, from: JournalDate? = nil, to: JournalDate? = nil) {
        self.accountName = accountName

        var balances: [String: Decimal] = [:]
        var prefixFlags: [String: Bool]  = [:]
        var resultLines: [Line]          = []

        let txs = ledger.journal.transactions
            .filter {
                if let f = from, $0.date < f { return false }
                if let t = to,   $0.date > t { return false }
                return $0.postings.contains { $0.accountName == accountName }
            }

        for tx in txs {
            for posting in tx.postings where posting.accountName == accountName {
                let c = posting.amount.commodity
                balances[c, default: .zero] += posting.amount.quantity
                prefixFlags[c] = posting.amount.commodityIsPrefix

                let runningBalance = balances.map { (commodity, qty) in
                    Amount(quantity: qty, commodity: commodity, commodityIsPrefix: prefixFlags[commodity] ?? false)
                }.sorted { $0.commodity < $1.commodity }

                resultLines.append(Line(transaction: tx, posting: posting, runningBalance: runningBalance))
            }
        }

        self.lines = resultLines
    }
}
