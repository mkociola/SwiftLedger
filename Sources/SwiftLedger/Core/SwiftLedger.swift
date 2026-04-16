// SwiftLedger — A plain-text accounting library for Swift.
//
// This library implements the plain-text accounting (PTA) model popularised by
// ledger-cli and hledger, supporting `.ledger` / `.journal` file formats.
//
// ## Quick start
//
// ```swift
// // Parse an existing journal file
// let parser  = JournalParser()
// let journal = try parser.parse(contents)
// let ledger  = Ledger(journal: journal)
//
// // Query balances
// let balance = ledger.balance(for: "Expenses:Food")
//
// // Post a new transaction programmatically
// var ledger = Ledger()
// let tx = try Transaction(
//     date: JournalDate(year: 2024, month: 6, day: 1),
//     description: "Coffee",
//     postings: [
//         Posting(
//             accountName: "Expenses:Food",
//             amount: Amount(quantity: 5, commodity: "$", commodityIsPrefix: true)),
//         Posting(accountName: "Assets:Checking",
//             amount: Amount(quantity: -5, commodity: "$", commodityIsPrefix: true)),
//     ]
// )
// ledger.add(.transaction(tx))
// ```
