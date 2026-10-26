// MARK: - Finishing a parse once every file is read

import Foundation

extension JournalParser {
    /// An entry as the parse read it, before its postings are resolved into a
    /// `Transaction`: the header, the posting lines as written, and what
    /// `Transaction` keeps besides them.
    struct RawEntry {
        var header: ParsedHeader
        var rawPostings: [RawPosting]
        var leadingComments: [String]
        /// The lines the entry was read from, for `Transaction.sourceText`.
        var source: String
        /// The header's 1-based line and its text, for locating an error
        /// found while finishing the entry the way `located(line:entry:)`
        /// locates one found while reading it.
        var lineNumber: Int
        var headerLine: String
    }

    /// What `parse(_:in:)` makes of one line or block: a finished item, an
    /// entry still to finish, or an `include` line with the files it read.
    enum ParsedItem {
        case item(JournalItem)
        case entry(RawEntry)
        case include(line: String, lineNumber: Int, files: [ParsedFile])
    }

    /// One file as `parse(_:in:)` read it, before `finish(_:)` turns it and
    /// the files it includes into a `Journal`.
    struct ParsedFile {
        var items: [ParsedItem]
        var style: JournalStyleCollector
        var lineEnding: LineEnding
        var file: URL?
    }

    /// A posting that writes a balance assertion and no amount: a balance
    /// assignment, as hledger reads it, which posts whatever brings the
    /// account to the asserted balance.
    static func isAssignment(_ raw: RawPosting) -> Bool {
        raw.amount == nil && raw.balanceAssertion != nil
    }

    /// The transaction `entry` reads as, its elided amounts resolved.
    func transaction(of entry: RawEntry) throws -> Transaction {
        let resolved = try resolveElisions(entry.rawPostings, year: entry.header.date.year)
        let transaction = try Transaction(
            date: entry.header.date,
            auxDate: entry.header.auxDate,
            status: entry.header.status,
            code: entry.header.code,
            description: entry.header.description,
            postings: resolved.postings,
            comment: entry.header.comment,
            leadingComments: entry.leadingComments,
            written: resolved.written,
        )
        // Keep the lines this came from, so that a transaction nobody edits is
        // written back exactly as the user wrote it.
        return transaction.taggedWithSource(entry.source)
    }

    /// hledger refuses a balance assignment on a posting its comments date,
    /// since the posting would count at one date and be computed at another,
    /// and so does this, at the posting's line, with hledger's words.
    func requireUndatedAssignment(_ raw: RawPosting, year: Int, entry: String) throws {
        guard raw.amount == nil, let asserted = raw.balanceAssertion else { return }
        try located(line: raw.lineNumber, entry: entry) {
            let dated = try Self.posting(from: raw, amount: asserted).datedByComments(year: year)
            guard dated.date == nil else {
                let message = "Balance assignments and custom posting dates may not be combined"
                throw LedgerError.parseError(line: raw.lineNumber, message: message)
            }
        }
    }

    // MARK: - Balance assignments

    /// The journal of `file` and the files it includes, every balance
    /// assignment filled in.
    ///
    /// An assignment is computed the way hledger computes one, from the
    /// account's running balance at that point in the journal, so it cannot
    /// be read where it stands: the balance counts every posting dated before
    /// the entry, in whichever file and wherever in the file it is written.
    /// hledger's order is followed exactly. A posting of an entry with no
    /// assignment counts at its own date, `Posting.date` or else the entry's;
    /// an entry with an assignment is processed whole at the entry's date;
    /// and items of one date keep document order, an included file's entries
    /// standing at its `include` line. Within such an entry the postings are
    /// taken in order, the written amounts and the assignments first, each
    /// assignment seeing the postings above it, and the elided amount, if
    /// any, inferred from what they leave over.
    ///
    /// An error finishing an entry is located as one reading it would be: at
    /// the entry's line, and for an entry in an included file also at each
    /// `include` line that led there.
    func finish(_ file: ParsedFile) throws -> Journal {
        var next = 0
        // The replay walks every posting, so a journal with nothing to
        // finish, which is most journals, is spared it.
        guard Self.hasUnfinishedEntry(file) else { return journal(of: file, taking: [], next: &next) }

        var entries: [(entry: RawEntry, locate: (LedgerError) -> LedgerError)] = []
        var steps: [(date: JournalDate, step: ReplayStep)] = []
        Self.collect(file, locate: { $0 }, into: &entries, steps: &steps)

        // By ordinal, which is document order, since the replay below meets
        // the entries in date order and `journal(of:taking:next:)` takes
        // them back in the order the files write them.
        var resolved = [Transaction?](repeating: nil, count: entries.count)
        var running: [String: Ledger.CommoditySums] = [:]
        let byDate = steps.indices.sorted { lhs, rhs in
            steps[lhs].date == steps[rhs].date ? lhs < rhs : steps[lhs].date < steps[rhs].date
        }
        for index in byDate {
            switch steps[index].step {
            case let .posting(posting):
                Ledger.accumulate(posting.amount, into: &running[posting.accountName, default: [:]])
            case let .entry(ordinal):
                do {
                    resolved[ordinal] = try assign(entries[ordinal].entry, running: &running)
                } catch let error as LedgerError {
                    throw entries[ordinal].locate(error)
                }
            }
        }
        return journal(of: file, taking: resolved.compactMap(\.self), next: &next)
    }

    /// Whether `file` or a file it includes holds an entry still to finish.
    private static func hasUnfinishedEntry(_ file: ParsedFile) -> Bool {
        file.items.contains { item in
            switch item {
            case .entry: true
            case let .include(_, _, files): files.contains(where: hasUnfinishedEntry)
            case .item: false
            }
        }
    }

    /// One thing the replay in `finish(_:)` meets: a posting already read, or
    /// an entry (by its index in the document-order list) still to finish.
    private enum ReplayStep {
        case posting(Posting)
        case entry(Int)
    }

    /// Walks `file` and the files it includes in document order, listing each
    /// posting and each unfinished entry with its date, and each unfinished
    /// entry with the way to locate an error in it: `locate` is the location
    /// of this file, and an included file's wraps it in the `include` line.
    private static func collect(
        _ file: ParsedFile,
        locate: @escaping (LedgerError) -> LedgerError,
        into entries: inout [(entry: RawEntry, locate: (LedgerError) -> LedgerError)],
        steps: inout [(date: JournalDate, step: ReplayStep)],
    ) {
        for item in file.items {
            switch item {
            case let .item(.transaction(transaction)):
                for posting in transaction.postings {
                    steps.append((posting.date ?? transaction.date, .posting(posting)))
                }
            case .item:
                continue
            case let .entry(entry):
                steps.append((entry.header.date, .entry(entries.count)))
                entries.append((entry, { locate(located($0, line: entry.lineNumber, entry: entry.headerLine)) }))
            case let .include(_, lineNumber, files):
                for child in files {
                    let path = child.file?.path ?? ""
                    collect(child, locate: { error in
                        let inFile = LedgerError.inIncludedFile(path, underlying: error)
                        return locate(.inJournal(line: lineNumber, entry: nil, underlying: inFile))
                    }, into: &entries, steps: &steps)
                }
            }
        }
    }

    /// `entry` with each assignment posting given the amounts it assigns,
    /// finished into a transaction, and `running` advanced by every posting
    /// of the entry: the written and assigned ones as they are met, so that an
    /// assignment sees the postings above it, and the inferred ones once the
    /// elision is resolved.
    private func assign(_ entry: RawEntry, running: inout [String: Ledger.CommoditySums]) throws -> Transaction {
        // ponytail: copies every account's sums per assignment entry; track the entry's own postings if that shows.
        let before = running
        var postings: [RawPosting] = []
        for raw in entry.rawPostings {
            guard Self.isAssignment(raw), let asserted = raw.balanceAssertion else {
                if let amount = raw.amount { Ledger.accumulate(amount, into: &running[raw.accountName, default: [:]]) }
                postings.append(raw)
                continue
            }
            let amounts = Self.assigned(
                asserted, operator: raw.balanceAssertionOperator, to: raw.accountName, in: running,
            )
            // The line's own fields go where `postings(from:amounts:year:)`
            // puts them. The assertion goes on the last leg, where hledger
            // prints it and where `Ledger.checkBalanceAssertions()` checks it
            // once every amount the line moved is counted: on an earlier leg
            // a `==` assertion would be checked before the other commodity
            // was cleared, and pass where hledger fails it.
            for (index, amount) in amounts.enumerated() {
                var leg = raw
                leg.amount = amount
                leg.balanceAssertion = index == amounts.count - 1 ? asserted : nil
                leg.price = index == 0 ? raw.price : nil
                leg.comment = index == 0 ? raw.comment : nil
                leg.trailingComments = index == amounts.count - 1 ? raw.trailingComments : []
                postings.append(leg)
                Ledger.accumulate(amount, into: &running[raw.accountName, default: [:]])
            }
        }
        var assigned = entry
        assigned.rawPostings = postings
        let transaction = try transaction(of: assigned)
        running = before
        for posting in transaction.postings {
            Ledger.accumulate(posting.amount, into: &running[posting.accountName, default: [:]])
        }
        return transaction
    }

    /// What an assignment of `asserted` to `account` posts, given the
    /// running balances, as hledger 1.52.4 computes it.
    ///
    /// hledger works out the balance the account is to have and posts the
    /// difference from the balance it measures. The balance to have is the
    /// asserted amount, and for `=` and `=*` also whatever else the account
    /// itself holds, since a single-commodity assertion speaks of one
    /// commodity; for `==` and `==*` it is the asserted amount alone, since
    /// the assertion says the account holds nothing else. The balance
    /// measured is the account's own for `=` and `==`, and the account's and
    /// its subaccounts' for `=*` and `==*`. So `=` posts the difference in
    /// one commodity, `==` also clears the others the account holds, `==*`
    /// clears the others the subtree holds, and `=*`, where the two balances
    /// differ, clears what only the subaccounts hold in another commodity,
    /// which is hledger's reading and is pinned by the conformance corpus.
    /// Costs play no part, and every kind of posting counts, as in
    /// `Ledger.checkBalanceAssertions()`. An amount of zero is dropped, as
    /// hledger drops it, and an assignment that moves nothing at all posts a
    /// single zero in no commodity, which is the `0` hledger prints for it.
    private static func assigned(
        _ asserted: Amount, operator kind: BalanceAssertionOperator, to account: String,
        in running: [String: Ledger.CommoditySums],
    ) -> [Amount] {
        var own: Ledger.CommoditySums = running[account] ?? [:]
        var measured: Ledger.CommoditySums = [:]
        let counts = { (name: String) in
            kind.isInclusive ? Ledger.isInSubtree(name, prefix: account) : name == account
        }
        for (name, sums) in running where counts(name) {
            for (commodity, sum) in sums {
                measured[commodity, default: (.zero, sum.isPrefix)].quantity += sum.quantity
            }
        }
        own[asserted.commodity] = nil
        var toHave: Ledger.CommoditySums = kind.isTotal ? [:] : own
        toHave[asserted.commodity] = (asserted.quantity, asserted.commodityIsPrefix)
        var posted: Ledger.CommoditySums = measured.mapValues { (-$0.quantity, $0.isPrefix) }
        for (commodity, sum) in toHave {
            posted[commodity, default: (.zero, sum.isPrefix)].quantity += sum.quantity
        }
        let amounts = Ledger.amounts(from: posted, dropZeros: true)
        return amounts.isEmpty ? [Amount(quantity: .zero, commodity: "")] : amounts
    }

    /// `file` as a `Journal`, each unfinished entry replaced by its
    /// transaction in `resolved`, which holds them in document order.
    private func journal(of file: ParsedFile, taking resolved: [Transaction], next: inout Int) -> Journal {
        var items: [JournalItem] = []
        for item in file.items {
            switch item {
            case let .item(item):
                items.append(item)
            case .entry:
                items.append(.transaction(resolved[next]))
                next += 1
            case let .include(line, _, files):
                let journals = files.map { journal(of: $0, taking: resolved, next: &next) }
                items.append(.include(IncludedFiles(line: line, journals: journals)))
            }
        }
        return Journal(items: items, style: file.style, lineEnding: file.lineEnding, file: file.file)
    }
}
