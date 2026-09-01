import Foundation

/// Watches how a journal writes each of its commodities, so that the serializer
/// can write a rebuilt posting the same way.
///
/// The parser feeds it the raw text of every amount it reads — posting amounts,
/// `@` prices and `= ` balance assertions alike — before that text becomes a
/// `Decimal` and loses its shape. What comes out is one `CommodityFormat` per
/// commodity the file mentions.
struct CommodityFormatCollector {
    /// The number of fraction digits seen for a commodity, and how often.
    private var fractionDigitCounts: [String: [Int: Int]] = [:]
    /// Per commodity: amounts large enough to show grouping that used a
    /// separator, and amounts large enough that did not.
    private var separated: [String: Int] = [:]
    private var unseparated: [String: Int] = [:]
    /// Per commodity, and only for the prefix style where the question arises:
    /// negative amounts written `-$50`, and negative amounts written `$-50`.
    private var signFirst: [String: Int] = [:]
    private var signAfterCommodity: [String: Int] = [:]
    /// Styles a `D` or `commodity` directive states outright.
    private var declared: [String: (fractionDigits: Int, groupsThousands: Bool)] = [:]

    /// Records how one amount was written.
    ///
    /// `raw` is the amount exactly as the file has it, commodity symbol and all
    /// — `$1,234.50`, `-1500.00 EUR`, `10 AAPL`. `amount` is what the parser
    /// made of it, so that the two always agree on which commodity was written
    /// and which way round it was.
    mutating func observe(_ raw: String, as amount: Amount) {
        guard let shape = NumberShape(raw) else { return }
        let commodity = amount.commodity
        fractionDigitCounts[commodity, default: [:]][shape.fractionDigits, default: 0] += 1
        if shape.canShowGrouping {
            if shape.usesSeparator {
                separated[commodity, default: 0] += 1
            } else {
                unseparated[commodity, default: 0] += 1
            }
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
    /// with whatever the file's own amounts show.
    mutating func declare(_ raw: String, commodity: String) {
        guard let shape = NumberShape(raw) else { return }
        declared[commodity] = (shape.fractionDigits, shape.usesSeparator)
    }

    /// The house style for every commodity the journal mentions.
    var formats: [String: CommodityFormat] {
        var result: [String: CommodityFormat] = [:]
        for (commodity, counts) in fractionDigitCounts {
            result[commodity] = CommodityFormat(
                fractionDigits: Self.mostCommon(counts),
                groupsThousands: Self.groups(
                    separated: separated[commodity] ?? 0,
                    unseparated: unseparated[commodity] ?? 0,
                ),
                // Ties, and files with no negative prefixed amount at all, keep
                // the placement SwiftLedger has always written.
                signPrecedesCommodity: (signFirst[commodity] ?? 0) >= (signAfterCommodity[commodity] ?? 0),
            )
        }
        // A declaration is the user stating their house style rather than the
        // parser guessing it from what they happened to type, so it wins —
        // including for a commodity no posting in the file uses yet.
        for (commodity, stated) in declared {
            var format = result[commodity] ?? CommodityFormat()
            format.fractionDigits = stated.fractionDigits
            format.groupsThousands = stated.groupsThousands
            result[commodity] = format
        }
        return result
    }

    // MARK: - Private

    /// The most frequent fraction-digit count, ties going to the longer one.
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
}

// MARK: - Number shape

/// The written shape of one amount: what the digits looked like before
/// `Decimal` normalised them away.
private struct NumberShape {
    var fractionDigits: Int
    var usesSeparator: Bool
    /// Whether the integer part is long enough for a thousands separator to
    /// have been visible at all.
    var canShowGrouping: Bool

    /// Reads the shape out of an amount as the file writes it.
    ///
    /// Takes the first run of `0-9`, `,` and `.` in the text, which is the
    /// number in every style the parser accepts: the commodity is either in
    /// front of it (`$1,234.50`, `-$50`) or behind it (`1,234.50 EUR`), and a
    /// sign on either side is not part of the run.
    init?(_ raw: String) {
        var digits = ""
        var started = false
        for character in raw {
            if character.isNumber || character == "," || character == "." {
                digits.append(character)
                started = true
            } else if started {
                break
            }
        }
        guard started, digits.contains(where: \.isNumber) else { return nil }

        usesSeparator = digits.contains(",")
        let integerText: String
        if let point = digits.lastIndex(of: ".") {
            integerText = String(digits[..<point])
            fractionDigits = digits[digits.index(after: point)...].count(where: \.isNumber)
        } else {
            integerText = digits
            fractionDigits = 0
        }
        canShowGrouping = integerText.count(where: \.isNumber) > 3
    }
}
