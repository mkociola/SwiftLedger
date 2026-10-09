import Foundation

/// Watches how a journal is written, so that the serializer can write a
/// rebuilt transaction the same way.
///
/// Two things, both lost by the time parsing is done. The parser feeds it the
/// raw text of every amount it reads — posting amounts, `@` prices and `= `
/// balance assertions alike — before that text becomes a `Decimal` and loses
/// its shape; and the column each posting's amount field starts at, before the
/// line is discarded. What comes out is one `CommodityFormat` per commodity the
/// file mentions, and the column the file lines its amounts up at.
struct JournalStyleCollector {
    /// The number of fraction digits seen for a commodity, and how often.
    private var fractionDigitCounts: [String: [Int: Int]] = [:]
    /// The same count over posting amounts alone, leaving out prices and
    /// balance assertions.
    private var postedFractionDigitCounts: [String: [Int: Int]] = [:]
    /// Per commodity: amounts large enough to show grouping that used a
    /// separator, and amounts large enough that did not.
    private var separated: [String: Int] = [:]
    private var unseparated: [String: Int] = [:]
    /// Per commodity, and only for the prefix style where the question arises:
    /// negative amounts written `-$50`, and negative amounts written `$-50`.
    private var signFirst: [String: Int] = [:]
    private var signAfterCommodity: [String: Int] = [:]
    /// Per commodity: amounts written with it in front of the number, those of
    /// them that left a space between the two, and amounts written with it
    /// behind.
    private var prefixed: [String: Int] = [:]
    private var spacedPrefix: [String: Int] = [:]
    private var suffixed: [String: Int] = [:]
    /// Per commodity: how many of its amounts wrote each decimal mark. An
    /// amount whose own marks could not be told apart casts no vote.
    private var decimalMarks: [String: [Character: Int]] = [:]
    /// What a `D` or `commodity` directive states for a commodity outright.
    private struct DeclaredStyle {
        var fractionDigits: Int
        var groupsThousands: Bool
        /// `nil` when the sample could not say which of its marks was which.
        var decimalMark: Character?
    }

    /// Styles a `D` or `commodity` directive states outright.
    private var declared: [String: DeclaredStyle] = [:]
    /// The column each posting's amount field began at, and each one ended at,
    /// with how often — the two conventions, counted against each other.
    private var amountStarts: [Int: Int] = [:]
    private var amountEnds: [Int: Int] = [:]
    /// The leading whitespace each posting line was written with, and how often.
    private var indents: [String: Int] = [:]

    /// Records how one amount was written.
    ///
    /// `shape` comes from the scan that read the amount, rather than from a
    /// second look at the text: only the parser knows whether the `.` in
    /// `1.000,00` grouped the thousands or divided the fraction, and a
    /// collector that guessed would record a style the file never used.
    /// `raw` is the amount exactly as the file has it, commodity symbol and
    /// all, which is all that is left to read the sign's placement out of.
    /// `amount` is what the parser made of it, so that the two always agree on
    /// which commodity was written and which way round it was. `posted` is
    /// true for a posting's own amount and false for a price or an assertion.
    mutating func observe(_ raw: String, shape: NumberShape, as amount: Amount, posted: Bool) {
        let commodity = amount.commodity
        fractionDigitCounts[commodity, default: [:]][shape.fractionDigits, default: 0] += 1
        if posted {
            postedFractionDigitCounts[commodity, default: [:]][shape.fractionDigits, default: 0] += 1
        }
        if shape.canShowGrouping {
            if shape.usesSeparator {
                separated[commodity, default: 0] += 1
            } else {
                unseparated[commodity, default: 0] += 1
            }
        }
        // One amount, one vote on the marks, however many of them it wrote:
        // `1.000,00` shows both and still counts once.
        if let mark = Self.decimalMark(of: shape) {
            decimalMarks[commodity, default: [:]][mark, default: 0] += 1
        }
        if amount.commodityIsPrefix {
            prefixed[commodity, default: 0] += 1
            // The parser took the space off the name, so the text is the only
            // place left that shows one was written.
            if let end = raw.range(of: commodity)?.upperBound, end < raw.endIndex, raw[end].isWhitespace {
                spacedPrefix[commodity, default: 0] += 1
            }
        } else if raw.contains(commodity) {
            // A bare number is read as USD without writing it on either side,
            // so it casts no vote.
            suffixed[commodity, default: 0] += 1
        }
        // Only a negative amount with its commodity in front can show which
        // side the sign goes on. `-1500.00 EUR` has nowhere else to put it.
        if amount.commodityIsPrefix, amount.quantity < 0 {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("+") {
                signFirst[commodity, default: 0] += 1
            } else {
                signAfterCommodity[commodity, default: 0] += 1
            }
        }
    }

    /// Records the style a directive states for a commodity, written the way
    /// ledger writes one — as a sample amount: `D $1,000.00`.
    ///
    /// A declaration says nothing about where a minus sign goes, so that stays
    /// with whatever the file's own amounts show. A sample that cannot say
    /// which of its marks was which, as `D 1.000 EUR` cannot, says nothing
    /// about the marks either and leaves them to the amounts in the same way.
    mutating func declare(_ shape: NumberShape, commodity: String) {
        declared[commodity] = DeclaredStyle(
            fractionDigits: shape.fractionDigits,
            groupsThousands: shape.usesSeparator,
            decimalMark: Self.decimalMark(of: shape),
        )
    }

    /// Records where a posting line's amount field began and ended.
    ///
    /// Only postings that write an amount say anything: an elided leg has no
    /// field to line up, and counting it would drag the answer toward zero.
    mutating func observeAmountField(start: Int, end: Int) {
        amountStarts[start, default: 0] += 1
        amountEnds[end, default: 0] += 1
    }

    /// How this file lines its amounts up, or `nil` when no posting showed —
    /// a journal built in code, or one whose every posting elides its amount.
    ///
    /// Both conventions are measured and the better-agreeing one wins. A file
    /// that ends its amounts at one column has as many agreeing ends as it has
    /// postings while its starts scatter by the width of each sign, and the
    /// reverse holds for a file SwiftLedger itself wrote. Ties go to `.start`,
    /// which is what this library has always produced.
    ///
    /// Within a convention it is the most common column, not the first or the
    /// widest: a file is allowed one long account name that pushes its own
    /// amount past the rest without that becoming the file's margin.
    var amountAlignment: AmountAlignment? {
        let start = Self.mode(amountStarts)
        let end = Self.mode(amountEnds)
        switch (start, end) {
        case (nil, nil): return nil
        case let (start?, nil): return .start(column: start.column)
        case let (nil, end?): return .end(column: end.column)
        case let (start?, end?):
            return end.count > start.count ? .end(column: end.column) : .start(column: start.column)
        }
    }

    /// The most common column and how many postings agreed on it.
    private static func mode(_ counts: [Int: Int]) -> (column: Int, count: Int)? {
        counts
            .max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key }
            .map { (column: $0.key, count: $0.value) }
    }

    /// Records the whitespace a posting line is indented with, verbatim, so a
    /// file written with two spaces or with tabs is not re-indented to four.
    mutating func observeIndent(_ indent: String) {
        guard !indent.isEmpty else { return }
        indents[indent, default: 0] += 1
    }

    /// The indent this file writes its postings with, or `nil` when it showed
    /// none. The most common one, ties going to the wider.
    var postingIndent: String? {
        indents.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.count < rhs.key.count
        }?.key
    }

    /// The house style for every commodity the journal mentions.
    var formats: [String: CommodityFormat] {
        var result: [String: CommodityFormat] = [:]
        for (commodity, counts) in fractionDigitCounts {
            // A commodity that is posted is written no longer than its
            // postings write it. A rate carries more digits than the money it
            // converts, and a journal of `33.33 EUR @ 1.0837 USD` against
            // `-36.12 USD` that let the rates vote would write a rebuilt cash
            // leg as `-36.1200 USD`, at which the entry no longer balances.
            //
            // Posted amounts lower the count and never raise it. Often only
            // a few are written: a journal that elides its cash legs has none
            // until a rebuild writes one remainder out in full, and that one
            // `-36.119721 USD` would otherwise become the house style and pad
            // every rate after it. Raising the count is also the unsafe
            // direction, since an entry is held to the digits it is written
            // in and more of them can refuse a rebuild that used to pass.
            let overall = Self.mostCommon(counts)
            let posted = postedFractionDigitCounts[commodity].map(Self.mostCommon) ?? overall
            let inFront = prefixed[commodity] ?? 0
            let spaced = spacedPrefix[commodity] ?? 0
            let behind = suffixed[commodity] ?? 0
            result[commodity] = CommodityFormat(
                fractionDigits: min(posted, overall),
                maxFractionDigits: counts.keys.max() ?? 0,
                groupsThousands: Self.groups(
                    separated: separated[commodity] ?? 0,
                    unseparated: unseparated[commodity] ?? 0,
                ),
                // Ties, and files with no negative prefixed amount at all, keep
                // the placement SwiftLedger has always written.
                signPrecedesCommodity: (signFirst[commodity] ?? 0) >= (signAfterCommodity[commodity] ?? 0),
                decimalMark: Self.mostCommonMark(decimalMarks[commodity] ?? [:]),
                // A tie goes behind the number, where `Amount.init` puts a
                // commodity it is told nothing about, and a commodity written
                // on neither side has shown none. The space has to win
                // outright, since writing none is the default.
                commodityIsPrefix: inFront + behind == 0 ? nil : inFront > behind,
                separatesPrefixCommodity: spaced > inFront - spaced,
            )
        }
        // A declaration is the user stating their house style rather than the
        // parser guessing it from what they happened to type, so it wins —
        // including for a commodity no posting in the file uses yet.
        for (commodity, stated) in declared {
            // Everything a declaration does not state is left to the amounts:
            // where the sign goes, where the commodity goes, and whether a
            // space follows it. The last two are unknown for a commodity that
            // has no amounts.
            var merged = result[commodity] ?? CommodityFormat()
            merged.fractionDigits = stated.fractionDigits
            // A declaration states how to write one, not how precisely the
            // file actually speaks, so it can raise the observed maximum but
            // never lower it.
            merged.maxFractionDigits = max(merged.maxFractionDigits, stated.fractionDigits)
            merged.groupsThousands = stated.groupsThousands
            // A declaration whose sample could not name a mark overrules
            // nothing here, and the amounts keep the vote.
            merged.decimalMark = stated.decimalMark ?? merged.decimalMark
            result[commodity] = merged
        }
        return result
    }

    // MARK: - Private

    /// The most frequent fraction-digit count, ties going to the longer one.
    ///
    /// Paired with `CommodityFormat.maxFractionDigits`, which takes the largest
    /// count instead — the two answer different questions for different
    /// callers, so both are recorded.
    ///
    /// The mode rather than the maximum, because one `$0.333` in a file of
    /// `$1,234.50` is an odd amount, not a house style, and taking the maximum
    /// would write every other amount as `$1,234.500`. The odd amount is still
    /// written in full: `CommodityFormat.fractionDigits` is a floor.
    private static func mostCommon(_ counts: [Int: Int]) -> Int {
        counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }?.key ?? 0
    }

    /// Whether to write separators, counting only amounts big enough to carry
    /// one: `$150.00` is not evidence either way, and in a file of `$1,234.50`
    /// there are far more of those than there are four-digit amounts.
    ///
    /// Ties go to grouping. Typing a separator is a deliberate act and leaving
    /// one out is what a hurried entry looks like, so a file that does both is
    /// likelier to mean the former.
    private static func groups(separated: Int, unseparated: Int) -> Bool {
        separated > 0 && separated >= unseparated
    }

    /// The decimal mark one written number is evidence for: the mark that
    /// divided its own fraction, or failing that the counterpart of the mark
    /// it grouped with, since a number grouping with `.` divides with `,`.
    ///
    /// `nil` is an abstention rather than a vote for the default: a number
    /// whose one mark had exactly three digits after it was read by the
    /// tie-break rather than by anything it said, and the file's real evidence
    /// should not be outvoted by numbers that had nothing to say.
    private static func decimalMark(of shape: NumberShape) -> Character? {
        shape.decimalMark ?? shape.groupMark.map(counterpart)
    }

    /// The other of the two characters a number's marks are written with.
    /// `CommodityFormat.groupMark` states the same rule from the other end.
    private static func counterpart(of mark: Character) -> Character {
        mark == "," ? "." : ","
    }

    /// The mark the most amounts wrote. There are two to choose between, so
    /// the count is between two numbers: `,` has to win outright, and a tie or
    /// a commodity whose every amount abstained leaves `.`, which is the
    /// default and what SwiftLedger has always written.
    private static func mostCommonMark(_ votes: [Character: Int]) -> Character {
        (votes[","] ?? 0) > (votes["."] ?? 0) ? "," : "."
    }
}
