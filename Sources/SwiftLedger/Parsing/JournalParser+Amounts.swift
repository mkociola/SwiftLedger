// MARK: - Posting amount parsing

import Foundation

extension JournalParser {
    /// An amount and the shape the file wrote its number in. Neither is
    /// recoverable from the other: a `Decimal` normalises its own scale and
    /// remembers no marks, and the text alone is not a number until something
    /// decides what its marks mean.
    struct ShapedAmount {
        var amount: Amount
        var shape: NumberShape
    }

    /// Parses an amount string such as `$100`, `-$50`, `$-50`, `100 USD`, `100.00`.
    ///
    /// The shape of the number is dropped here. Everything inside the parser
    /// calls `parseShapedAmount` instead and hands the shape to the style
    /// collector, so that what the file teaches about a commodity comes from
    /// the same reading that produced the value.
    func parseAmount(_ raw: String, lineNumber: Int) throws -> Amount {
        try parseShapedAmount(raw, lineNumber: lineNumber).amount
    }

    /// Parses an amount and reports how its number was written.
    ///
    /// The commodity sits in front of the number (`$100`, `-$50`, `$-50`) or
    /// behind it (`100 USD`, `1.000,00 EUR`), and the number itself is read by
    /// `scanNumber`, which takes digits and marks and nothing else. Anything
    /// it refuses is `LedgerError.invalidAmount`, carrying the text as the
    /// file wrote it. Where in the file it was written is added by the caller,
    /// which is why the line number handed in here goes unused: a posting's
    /// amount is located against the posting's own line by `parseTransaction`,
    /// while the sample amount of a `D` directive belongs to no entry at all.
    ///
    /// Validating the number rather than trusting `Decimal(string:)` is the
    /// point of this path. That initialiser keeps the longest prefix that
    /// parses and drops the rest in silence, so `$1e5` used to load as 100000
    /// and `$1x2y` as 1, and a journal of such amounts balanced and reported
    /// figures nobody had written (issue #18).
    ///
    /// `style` is what the file has declared above this amount, which is the
    /// only thing that can settle a number the text alone cannot (see
    /// `scanNumber`). An amount read on its own, as `parseAmount` reads one,
    /// has no file above it and gets the tie-break.
    func parseShapedAmount(
        _ raw: String,
        lineNumber _: Int,
        in style: JournalStyleCollector = JournalStyleCollector(),
    ) throws -> ShapedAmount {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw LedgerError.invalidAmount(raw) }

        var str = trimmed
        var sign = Decimal(1)
        if str.hasPrefix("-") {
            sign = -1
            str = String(str.dropFirst())
        } else if str.hasPrefix("+") {
            str = String(str.dropFirst())
        }
        // A space after the sign is layout too. Left on, it sent `- 100` down
        // the prefix path as a commodity made of that space, where `-100` is
        // a bare number.
        str = str.trimmingCharacters(in: .whitespaces)

        guard let first = str.first else { throw LedgerError.invalidAmount(raw) }
        if Self.opensNumber(first) {
            return try parseSuffixCommodityAmount(str, sign: sign, raw: raw, in: style)
        }
        return try parsePrefixCommodityAmount(str, sign: sign, raw: raw, in: style)
    }

    /// `$100`, `$-50`, `€1.000,00`: the commodity runs up to the first
    /// character that could open a number, and everything after it is the
    /// number, its own sign included.
    ///
    /// Everything, which is what makes `$100 USD` and `$1 000` invalid rather
    /// than 100 and 1. A prefixed amount names its commodity once, so text
    /// left over after the digits is not a second commodity, it is a typo.
    ///
    /// A space between the two is layout and no part of the name, the same as
    /// behind the number: `USD 100` is a hundred `USD`, as hledger reads it.
    /// Kept in the name, it made `USD 100` and `USD100` two commodities, and
    /// an entry rebuilt by a caller that spelled it `USD` stopped netting
    /// against every other entry in the file. `CommodityFormat` records that
    /// the file writes the space, so a rebuilt entry still gets it back.
    ///
    /// The name cannot be empty. The caller has taken one sign off already,
    /// so in `--5` or `+-5` the second stands where the commodity would, and
    /// read on it made five of a commodity called nothing. hledger refuses
    /// these and still reads a sign on each side of a commodity, `-$-5`.
    private func parsePrefixCommodityAmount(
        _ str: String,
        sign: Decimal,
        raw: String,
        in style: JournalStyleCollector,
    ) throws -> ShapedAmount {
        let commodityEnd = str.firstIndex(where: Self.opensSignedNumber) ?? str.endIndex
        let commodity = str[..<commodityEnd].trimmingCharacters(in: .whitespaces)
        guard !commodity.isEmpty else { throw LedgerError.invalidAmount(raw) }
        var numberText = String(str[commodityEnd...])
        var adjustedSign = sign
        if numberText.hasPrefix("-") {
            adjustedSign *= -1
            numberText = String(numberText.dropFirst())
        } else if numberText.hasPrefix("+") {
            numberText = String(numberText.dropFirst())
        }

        guard let number = Self.scanNumber(
            numberText.trimmingCharacters(in: .whitespaces),
            declaredMark: style.declaredDecimalMark(for: commodity),
        ) else {
            throw LedgerError.invalidAmount(raw)
        }
        return ShapedAmount(
            amount: Amount(
                quantity: adjustedSign * number.magnitude,
                commodity: commodity,
                commodityIsPrefix: true,
            ),
            shape: number.shape,
        )
    }

    /// `100 USD`, `10 AAPL`, `12,50 EUR`, and a bare `100`: the number is the
    /// leading run of digits and marks, and what follows it names the
    /// commodity.
    ///
    /// A remainder beginning where the number could have carried on means the
    /// run stopped short rather than the commodity starting, so `1 000 EUR`
    /// and `1-2` are invalid instead of a thousandth of what was meant and a
    /// commodity called `-2`. A remainder carrying a digit is refused for the
    /// same reason: neither ledger-cli nor hledger lets an unquoted commodity
    /// symbol hold one, so `1e5` and `1x2y` are a number someone mistyped
    /// rather than one unit of `e5` and one of `x2y`. A remainder that is
    /// empty leaves the `USD` a bare number has always been read as; hledger
    /// reads it as an amount in no commodity at all, and that is a separate
    /// question from this one.
    private func parseSuffixCommodityAmount(
        _ str: String,
        sign: Decimal,
        raw: String,
        in style: JournalStyleCollector,
    ) throws -> ShapedAmount {
        let end = str.firstIndex { !Self.opensNumber($0) } ?? str.endIndex
        let remainder = String(str[end...]).trimmingCharacters(in: .whitespaces)
        guard !Self.cutsNumberShort(remainder),
              !Self.commodityCarriesDigit(remainder),
              let number = Self.scanNumber(
                  String(str[..<end]),
                  declaredMark: style.declaredDecimalMark(for: remainder.isEmpty ? nil : remainder),
              )
        else {
            throw LedgerError.invalidAmount(raw)
        }
        return ShapedAmount(
            amount: Amount(
                quantity: sign * number.magnitude,
                commodity: remainder.isEmpty ? "USD" : remainder,
                commodityIsPrefix: false,
            ),
            shape: number.shape,
        )
    }

    // MARK: - Reading a written number

    /// A number as the file wrote it: the unsigned value, and its shape.
    private struct ScannedNumber {
        var magnitude: Decimal
        var shape: NumberShape
    }

    /// Whether `character` can open the number part of an amount: an ASCII
    /// digit, or one of the two marks. See `Character.isASCIIDigit` for why
    /// the digits are counted the narrow way.
    static func opensNumber(_ character: Character) -> Bool {
        character.isASCIIDigit || character == "." || character == ","
    }

    /// The same, plus the sign that may sit between a prefix commodity and its
    /// digits: `$-50`.
    static func opensSignedNumber(_ character: Character) -> Bool {
        opensNumber(character) || character == "-" || character == "+"
    }

    /// Whether what follows a number could have been part of it, which means
    /// the digits stopped short rather than the commodity starting.
    static func cutsNumberShort(_ remainder: String) -> Bool {
        guard let first = remainder.first else { return false }
        return opensSignedNumber(first)
    }

    /// Whether a commodity written after the number holds a digit, which an
    /// unquoted symbol may not do in either tool.
    ///
    /// A quoted symbol may hold anything and is taken exactly as written,
    /// quotes included: the quoting is not modelled here, and `10 "AAPL 2"`
    /// is a line that loaded before and has to go on loading.
    static func commodityCarriesDigit(_ remainder: String) -> Bool {
        guard !remainder.hasPrefix("\"") else { return false }
        return remainder.contains(where: \.isASCIIDigit)
    }

    /// Reads a written number: ASCII digits, at most one decimal mark, and
    /// group marks sitting between digits. Both marks are written `.` or `,`
    /// depending on where the file comes from, so which is which is read out
    /// of the number rather than assumed.
    ///
    /// The rules are hledger's, with the tie-break ledger-cli and SwiftLedger
    /// have always used where the file declares nothing:
    ///
    /// - two different marks: the last one divides the fraction and the other
    ///   groups, so `1,000.00` and `1.000,00` are both one thousand and
    ///   `12.345,678` is twelve thousand odd;
    /// - one mark written more than once: all of them group and there is no
    ///   fraction, so `1.000.000` is a million and `1,00,000` is a hundred
    ///   thousand;
    /// - one mark, and a directive above the number: `declaredMark` is what
    ///   the file's `commodity`, `D` or `decimal-mark` directives say the
    ///   decimal mark is (`JournalStyleCollector.declaredDecimalMark(for:)`).
    ///   The mark divides when it is that one and groups otherwise, whatever
    ///   follows it, so `€1.000` under `commodity €1.000,00` is a thousand
    ///   and `€12.50` under `decimal-mark ,` is twelve hundred and fifty. A
    ///   mark with nothing on one side of it divides either way, since there
    ///   is nothing there to group;
    /// - one mark and no directive, with nothing but zeros in front of it: it
    ///   divides, whatever follows, because there is nothing there to group,
    ///   so `0,500` is half a unit and `€0,750` three quarters of one;
    /// - one mark and no directive, with exactly three digits after it:
    ///   nothing in the number says which it is, and the reading kept is the
    ///   one this library and ledger-cli have always had, `,` groups and `.`
    ///   divides, so `1,000` is a thousand and `1.000` is one; hledger reads
    ///   `1,000` as one instead;
    /// - one mark and no directive, with any other count of digits after it,
    ///   none included: it divides, so `12,50` is 12.5, `1,0000` is 1 and
    ///   `5,` is 5.
    ///
    /// Group widths are not policed beyond being non-empty, which is hledger's
    /// reading: Indian grouping (`1,00,000`) is a hundred thousand there and
    /// here, while ledger-cli insists on groups of three and refuses it.
    private static func scanNumber(_ text: String, declaredMark: Character?) -> ScannedNumber? {
        let characters = Array(text)
        guard !characters.isEmpty,
              characters.allSatisfy(opensNumber),
              characters.contains(where: \.isASCIIDigit) else { return nil }

        let marks = characters.indices.filter { !characters[$0].isASCIIDigit }
        let reading = markReading(in: characters, marks: marks, declaredMark: declaredMark)
        let groups = marks.filter { $0 != reading.decimal }
        guard groupsAreWellPlaced(groups, in: characters) else { return nil }
        return number(from: characters, decimal: reading.decimal, groups: groups, isSettled: reading.isSettled)
    }

    /// How the marks of one number were read.
    private struct MarkReading {
        /// Which mark divides the fraction, as an index into the number, or
        /// `nil` when every mark groups and the number has no fraction at all.
        var decimal: Int?
        /// Whether the number itself or a directive settled that, rather than
        /// the tie-break settling it for the number. A reading is made either
        /// way, since a value has to come out; only what the number is allowed
        /// to say about the file's convention turns on this.
        var isSettled: Bool
    }

    /// Tells the marks of a number apart.
    private static func markReading(in characters: [Character], marks: [Int], declaredMark: Character?) -> MarkReading {
        guard let last = marks.last else { return MarkReading(decimal: nil, isSettled: true) }
        if Set(marks.map { characters[$0] }).count > 1 { return MarkReading(decimal: last, isSettled: true) }
        if marks.count > 1 { return MarkReading(decimal: nil, isSettled: true) }
        let integerPart = characters[..<last]
        // A directive settles a lone mark outright, as hledger reads it: the
        // declared mark divides, and any other mark groups whatever follows
        // it, so `€12.50` under `decimal-mark ,` is twelve hundred and fifty.
        // A mark with nothing on one side of it divides under either
        // directive, since there is nothing there to group: `€.500` under
        // `decimal-mark ,` is half a euro and `€5.` is five, here and in
        // hledger, where read as a group mark either was no number at all
        // and the file stopped loading.
        if let declaredMark {
            let divides = integerPart.isEmpty || last == characters.count - 1 || characters[last] == declaredMark
            return MarkReading(decimal: divides ? last : nil, isSettled: true)
        }
        // Nothing groups a zero, so a lone mark with only zeros in front of it
        // divides however many digits follow it: `0,500` is half a unit. An
        // empty integer part is not that case, and with no directive to say
        // what the mark is, `,000` stays a group mark with nothing on its left,
        // which is no number at all.
        if !integerPart.isEmpty, integerPart.allSatisfy({ $0 == "0" }) {
            return MarkReading(decimal: last, isSettled: true)
        }
        guard characters.count - last - 1 == 3 else { return MarkReading(decimal: last, isSettled: true) }
        // The one shape the number cannot settle on its own. It gets the
        // tie-break, and abstains from the vote on the file's marks.
        return MarkReading(decimal: characters[last] == "." ? last : nil, isSettled: false)
    }

    /// Whether every group mark is the same character, written between two
    /// digits.
    ///
    /// `,000`, `1,,000`, `1,000,` and `1,.5` fail on the digits, and
    /// `1.000,000.00` fails on the character: its last mark divides, which
    /// leaves a `.` and a `,` both claiming to group, and a number cannot
    /// group two ways at once.
    private static func groupsAreWellPlaced(_ groups: [Int], in characters: [Character]) -> Bool {
        guard let mark = groups.first.map({ characters[$0] }) else { return true }
        return groups.allSatisfy { index in
            characters[index] == mark
                && index > 0 && characters[index - 1].isASCIIDigit
                && index < characters.count - 1 && characters[index + 1].isASCIIDigit
        }
    }

    /// The value and the shape, once the marks have been told apart. The
    /// fraction needs no filtering: the decimal mark is the last mark there
    /// is, so nothing but digits follows it.
    ///
    /// The marks go into the shape as the characters the number actually
    /// wrote, read the way they were read, and `isSettled` says whether that
    /// reading was the number's own or the tie-break's. See `NumberShape` for
    /// what turns on it.
    private static func number(
        from characters: [Character],
        decimal: Int?,
        groups: [Int],
        isSettled: Bool,
    ) -> ScannedNumber? {
        let integerDigits = characters[..<(decimal ?? characters.count)].filter(\.isASCIIDigit)
        let fractionDigits = decimal.map { Array(characters[($0 + 1)...]) } ?? []
        var text = integerDigits.isEmpty ? "0" : String(integerDigits)
        if !fractionDigits.isEmpty { text += "." + String(fractionDigits) }

        guard let magnitude = Decimal(string: text) else { return nil }
        return ScannedNumber(
            magnitude: magnitude,
            shape: NumberShape(
                fractionDigits: fractionDigits.count,
                usesSeparator: !groups.isEmpty,
                canShowGrouping: integerDigits.count > 3,
                decimalMark: decimal.map { characters[$0] },
                groupMark: groups.first.map { characters[$0] },
                isSettled: isSettled,
            ),
        )
    }
}

private extension Character {
    /// `0` through `9`, and nothing else.
    ///
    /// `isNumber` on its own is true of `½`, of `²` and of the digits of every
    /// other script, none of which `Decimal(string:)` reads. A range test over
    /// `"0" ... "9"` is worse than either half: a `Character` compares as the
    /// string it is, so `5` with a combining acute sorts inside that range,
    /// passes every check the scanner makes and reaches `Decimal(string:)`,
    /// which keeps the 5 and drops the accent along with the rest of the
    /// number.
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
