import Foundation

/// How one commodity's amounts are written in a particular journal: how many
/// digits follow the decimal point, whether the integer part carries thousands
/// separators, and which side of the symbol a minus sign goes on.
///
/// `Decimal` cannot answer either question. It normalises its own scale on
/// construction — `Decimal(string: "1240.50")` and `Decimal(string: "1240.5")`
/// are the same value, exponent and all — and the parser strips `,` before it
/// ever reaches a number. So an amount read back out of the model has no memory
/// of the way it was written, and a posting the caller rebuilt would be written
/// `$1240.5` where the user had `$1,240.50`.
///
/// A journal answers both questions about itself, which is what this type
/// records. `JournalParser` watches how each commodity is written and hands
/// `Journal.commodityFormats` the house style it found; `JournalSerializer`
/// writes a rebuilt posting in that style. The two rules compose:
///
/// - a transaction nobody touched is replayed from `Transaction.sourceText`,
///   byte for byte, and never consults this at all;
/// - a transaction that was edited is re-rendered in the style the rest of the
///   file already uses, so the diff shows the edit and nothing else.
///
/// This lives on the journal rather than on `Amount` on purpose. An `Amount` is
/// a value that gets added, negated and rebuilt from parts all over a caller's
/// code — Balance's edit sheet takes a posting apart into a quantity and a
/// commodity and puts it back together on save — so formatting carried on the
/// amount would be dropped by exactly the edits that need it most. It would
/// also have to be kept out of `==`, `hash` and `Codable`, the way
/// `Transaction.sourceText` is, or `Journal.remove(_:)` would start matching on
/// how a number was typed. Keyed by commodity, none of that arises.
public struct CommodityFormat: Sendable, Codable, Hashable {
    /// How many digits to write after the decimal point, at minimum.
    ///
    /// A minimum, never a maximum: a value that needs more digits than this is
    /// written with all of them. Rounding an amount to a display style would
    /// change what the journal says, and a rounded posting can leave a
    /// transaction that no longer balances.
    public var fractionDigits: Int

    /// Whether the integer part is written in three-digit groups separated by
    /// `,` — `$1,234.50` rather than `$1234.50`.
    public var groupsThousands: Bool

    /// Where the minus sign goes on a negative amount whose commodity comes
    /// first: `-$50` when `true`, `$-50` when `false`.
    ///
    /// Both are valid and the parser reads either, so which one a file uses is
    /// the author's choice and not the library's to overturn. `true` is the
    /// default because it is what SwiftLedger has always written.
    public var signPrecedesCommodity: Bool

    public init(
        fractionDigits: Int = 0,
        groupsThousands: Bool = false,
        signPrecedesCommodity: Bool = true,
    ) {
        self.fractionDigits = fractionDigits
        self.groupsThousands = groupsThousands
        self.signPrecedesCommodity = signPrecedesCommodity
    }

    /// The style to write a commodity in when the journal shows no example of
    /// it: an empty file, or a commodity the caller is introducing.
    ///
    /// Two decimal places for a commodity written as a symbol — `$`, `£`, `€` —
    /// because a symbol is a currency and a currency written `$12.5` reads as
    /// broken. Nothing for anything else: `USD` may well be a currency too, but
    /// `AAPL` and `BTC` are not, they are spelled the same way, and padding a
    /// share count to `10.00 AAPL` is worse than leaving it alone. One amount
    /// in the file settles it either way, and from then on inference decides.
    public static func `default`(for commodity: String) -> CommodityFormat {
        let isSymbol = !commodity.isEmpty && commodity.allSatisfy { !$0.isLetter && !$0.isNumber }
        return CommodityFormat(fractionDigits: isSymbol ? 2 : 0)
    }

    /// Renders an unsigned quantity in this style.
    ///
    /// The caller supplies the magnitude and writes the sign itself, so that a
    /// prefix commodity can put the sign where the journal puts it.
    public func render(_ magnitude: Decimal) -> String {
        // `Decimal.description` is the only locale-free rendering Foundation
        // offers: no grouping, no rounding, and every significant digit. It is
        // the raw material here, not the answer — the answer pads it.
        let plain = magnitude.description
        // Astronomically large or small values come back in exponent notation,
        // which has no integer and fraction part to pad or group. Nothing in a
        // journal reaches that range, and mangling one would be worse than
        // leaving it as the library has always written it.
        guard !plain.contains("e"), !plain.contains("E") else { return plain }

        var integerDigits = plain
        var fractionDigits = ""
        if let point = plain.firstIndex(of: ".") {
            integerDigits = String(plain[..<point])
            fractionDigits = String(plain[plain.index(after: point)...])
        }

        if fractionDigits.count < self.fractionDigits {
            fractionDigits += String(repeating: "0", count: self.fractionDigits - fractionDigits.count)
        }
        if groupsThousands {
            integerDigits = Self.grouped(integerDigits)
        }
        return fractionDigits.isEmpty ? integerDigits : "\(integerDigits).\(fractionDigits)"
    }

    /// `1234567` → `1,234,567`.
    private static func grouped(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var reversed: [Character] = []
        for (offset, digit) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { reversed.append(",") }
            reversed.append(digit)
        }
        return String(reversed.reversed())
    }
}
