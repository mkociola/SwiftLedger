import Foundation
@testable import SwiftLedger
import Testing

/// An `alias` or `apply account` line changes the account a posting below it
/// is booked under, as hledger reads it, while the file keeps the name it
/// wrote. The hledger conformance corpus pins the reading; these pin what the
/// model keeps of the written name and what a rebuilt entry writes back,
/// which no fixture can show.
@Suite("alias and apply account rewrite account names") struct AccountNameRewriteTests {
    static let journal = """
    alias checking = Assets:Checking
    alias /^exp:(.*)/ = Expenses:\\1

    2024-01-01 Rent
        Exp:Rent           $1200.00
        Assets:Savings     $-200.00
        checking

    2024-01-02 Groceries
        Exp:Food           $20.00
        Exp:Food           €5.00
        checking

    end aliases
    apply account Personal
    account cash

    2024-01-03 Pocket money
        cash               $10.00
        Assets:Checking

    end apply account
    """

    private static func rebuilt(_ transaction: Transaction, postings: [Posting]? = nil) throws -> Transaction {
        try Transaction(
            id: transaction.id, date: transaction.date, description: transaction.description,
            postings: postings ?? transaction.postings,
        )
    }

    private static func dollars(_ quantity: Decimal) -> Amount {
        Amount(quantity: quantity, commodity: "$", commodityIsPrefix: true)
    }

    @Test
    func `a posting is booked under the rewritten name and keeps the one it was written under`() throws {
        let rent = try #require(JournalParser().parse(Self.journal).transactions.first)
        #expect(rent.postings.map(\.accountName) == ["Expenses:Rent", "Assets:Savings", "Assets:Checking"])
        #expect(rent.postings.map(\.writtenAccountName) == ["Exp:Rent", nil, "checking"])
    }

    @Test
    func `an account directive is declared under the rewritten name`() throws {
        let journal = try JournalParser().parse(Self.journal)
        let cash = try #require(journal.accountDirectives.first)
        #expect(cash.name == "Personal:cash")
        #expect(cash.writtenName == "cash")
        #expect(JournalSerializer().serialize(journal).contains("\naccount cash\n"))
    }

    @Test
    func `a rebuilt entry writes the names the file wrote`() throws {
        var journal = try JournalParser().parse(Self.journal)
        for old in journal.transactions {
            let replaced = try journal.replace(.transaction(old), with: .transaction(Self.rebuilt(old)))
            #expect(replaced)
        }
        let text = JournalSerializer().serialize(journal)
        #expect(!text.contains("    Expenses:"))
        #expect(!text.contains("    Personal:"))
        let reread = try JournalParser().parse(text)
        #expect(reread.transactions.map(\.postings) == journal.transactions.map(\.postings))
    }

    /// The elided line absorbed two commodities and became two postings, and
    /// both are written back under the name the line wrote.
    @Test
    func `every leg of a split elided line keeps the written name`() throws {
        let groceries = try #require(JournalParser().parse(Self.journal).transactions.dropFirst().first)
        let legs = groceries.postings.filter { $0.accountName == "Assets:Checking" }
        #expect(legs.count == 2)
        #expect(legs.allSatisfy { $0.writtenAccountName == "checking" })
    }

    /// A posting built in code has no written name. Written as booked under
    /// `apply account`, the next parse would put the prefix on a second time.
    @Test
    func `a posting built in code under apply account is written without the prefix`() throws {
        var journal = try JournalParser().parse(Self.journal)
        let pocket = try #require(journal.transactions.last)
        let replacement = try Self.rebuilt(pocket, postings: [
            Posting(accountName: "Personal:Expenses:Food", amount: Self.dollars(30)),
            Posting(accountName: "Personal:cash", amount: Self.dollars(-30)),
        ])
        let replaced = journal.replace(.transaction(pocket), with: .transaction(replacement))
        #expect(replaced)
        let text = JournalSerializer().serialize(journal)
        let reread = try #require(JournalParser().parse(text).transactions.last)
        #expect(reread.postings.map(\.accountName) == ["Personal:Expenses:Food", "Personal:cash"])
    }

    /// Moved to the end of the file, below `end aliases`, `checking` would book a different account,
    /// so the posting is written under the name it is booked under.
    @Test
    func `a written name that no longer reads back gives way to the booked one`() throws {
        var journal = try JournalParser().parse(Self.journal)
        let groceries = try #require(journal.transactions.dropFirst().first)
        let removed = journal.remove(.transaction(groceries))
        #expect(removed)
        try journal.append(.transaction(Self.rebuilt(groceries)))
        let text = JournalSerializer().serialize(journal)
        let reread = try #require(JournalParser().parse(text).transactions.last)
        #expect(reread.postings.map(\.accountName) == groceries.postings.map(\.accountName))
    }

    /// A document SwiftLedger did not write is held to the rules the name it
    /// is booked under is held to, since the written name is the one put on
    /// the line.
    @Test(arguments: ["check\\ning", "check  ing", "(checking)"])
    func `a decoded written name the next parse would misread is refused`(written: String) throws {
        let rent = try #require(JournalParser().parse(Self.journal).transactions.first)
        let json = try #require(String(data: JSONEncoder().encode(rent), encoding: .utf8))
        #expect(json.contains("\"checking\""))
        let broken = json.replacingOccurrences(of: "\"checking\"", with: "\"\(written)\"")
        #expect(throws: LedgerError.self) {
            try JSONDecoder().decode(Transaction.self, from: Data(broken.utf8))
        }
    }

    @Test
    func `a decoded account directive with a written name the next parse would misread is refused`() throws {
        let cash = try #require(JournalParser().parse(Self.journal).accountDirectives.first)
        let json = try #require(String(data: JSONEncoder().encode(cash), encoding: .utf8))
        #expect(json.contains("\"cash\""))
        let broken = json.replacingOccurrences(of: "\"cash\"", with: "\"ca  sh\"")
        #expect(throws: LedgerError.self) {
            try JSONDecoder().decode(AccountDirective.self, from: Data(broken.utf8))
        }
    }
}
