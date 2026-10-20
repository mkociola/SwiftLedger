import Foundation
@testable import SwiftLedger
import Testing

/// A `decimal-mark`, `commodity` or `D` line speaks from where it stands to
/// the next one, and the house style (`Journal.commodityFormats`) carries one
/// mark per commodity for the whole file, which used to be the one in force
/// at its end. A rebuilt entry above a switch was written with that mark, and
/// read back a thousandfold off in the region it stands in, here and in
/// hledger (issue #80). The serializer now reads the directives as it writes
/// and gives a rebuilt amount the mark in force where its entry stands, and
/// the house style keeps the mark the amounts themselves show.
@Suite("the decimal mark in force where an entry stands") struct DecimalMarkRegionTests {
    /// One layout, the commodity the rent entry is rebuilt in, and what an
    /// eighth is written as where that entry stands. hledger 1.52.4 reads
    /// every one of the written amounts as an eighth; the first two are
    /// pinned in `decimal-mark-switch.journal`.
    struct Layout {
        var journal: String
        var symbol = "€"
        var written: String
    }

    static let layouts: [Layout] = [
        // The journal from the issue: the comma is in force where the entry
        // stands, and the point only below it.
        Layout(journal: """
        decimal-mark ,

        2024-01-01 rent
            expenses:rent    €1000
            assets:bank     €-1000

        decimal-mark .

        2024-02-01 fees
            expenses:fees    $1.50
            assets:bank     $-1.50
        """, written: "€1,125"),
        // The reverse layout: the file ends on the comma, and the entry
        // stands under the point.
        Layout(journal: """
        decimal-mark .

        2024-01-01 rent
            expenses:rent    €1000
            assets:bank     €-1000

        decimal-mark ,

        2024-02-01 fees
            expenses:fees    €1,50
            assets:bank     €-1,50
        """, written: "€1.125"),
        // A `D` line is read from where it stands as well, and reaches a
        // commodity with no declaration of its own.
        Layout(journal: """
        D €1.000,00

        2024-01-01 rent
            expenses:rent    $1000
            assets:bank     $-1000

        decimal-mark .

        2024-02-01 fees
            expenses:fees    $1.50
            assets:bank     $-1.50
        """, symbol: "$", written: "$1,125"),
        // A commodity the file has no amount in is written by the mark in
        // force too, rather than by the point of the default style.
        Layout(journal: """
        decimal-mark ,

        2024-01-01 rent
            expenses:rent    €1000
            assets:bank     €-1000

        decimal-mark .
        """, symbol: "$", written: "$1,125"),
        // Above every directive nothing is in force and the file's own mark
        // stands, and a lone mark divides there, so it reads back right too.
        Layout(journal: """
        2024-01-01 rent
            expenses:rent    €1000
            assets:bank     €-1000

        decimal-mark ,

        2024-02-01 fees
            expenses:fees    €1,50
            assets:bank     €-1,50
        """, written: "€1,125"),
        // A directive inside a `comment` block is text the parser reads
        // nothing from, so it declares nothing for the entry below it.
        Layout(journal: """
        decimal-mark ,

        comment
        decimal-mark .
        end comment

        2024-01-01 rent
            expenses:rent    €1000
            assets:bank     €-1000
        """, written: "€1,125"),
    ]

    /// An eighth rebuilt where the rent entry stands is written with the mark
    /// in force there, and reads back as an eighth.
    @Test(arguments: DecimalMarkRegionTests.layouts)
    func `a rebuilt amount is written with the mark in force where it stands`(layout: Layout) throws {
        var journal = try JournalParser().parse(layout.journal)
        let rent = try #require(journal.transactions.first)
        let eighth = try #require(Decimal(string: "1.125"))
        let money = { Amount(quantity: $0, commodity: layout.symbol, commodityIsPrefix: true) }
        let rebuilt = try Transaction(
            id: rent.id, date: rent.date, description: rent.description, postings: [
                Posting(accountName: "expenses:rent", amount: money(eighth)),
                Posting(accountName: "assets:bank", amount: money(-eighth)),
            ],
        )
        let replaced = journal.replace(.transaction(rent), with: .transaction(rebuilt))
        #expect(replaced)

        let written = JournalSerializer().serialize(journal)
        #expect(written.contains(" \(layout.written)\n"))
        let reparsed = try #require(JournalParser().parse(written).transactions.first)
        #expect(reparsed.postings.map(\.amount.quantity) == [eighth, -eighth])
    }
}
