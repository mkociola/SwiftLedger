// MARK: - A commodity symbol in double quotes

import Foundation

extension JournalParser {
    /// Reads the symbol inside the double quotes `text` opens with, and hands
    /// back what follows the closing quote: `"Mutual Fund" 10` is the symbol
    /// `Mutual Fund` and the rest ` 10`. `nil` when `text` opens with no
    /// quote, which leaves the bare grammar to read it. A quote with no
    /// partner is refused, as hledger refuses it, naming the amount as the
    /// file wrote it. Nothing between the quotes is a symbol of nothing,
    /// which the caller reads as hledger reads it: the number is bare.
    ///
    /// hledger's rule: a symbol holding a space, a digit or punctuation is
    /// written in double quotes, and the quotes are no part of the name, so
    /// `10 "Mutual Fund"` is ten units of `Mutual Fund` and `10 "USD"` is ten
    /// `USD`. Read with the quotes kept, as they used to be, the fund was a
    /// commodity nobody could query by name, and the moment an entry was
    /// rebuilt with the bare name the account split in two (issue #38). What
    /// stands between the quotes is not policed here: a `;` has opened the
    /// comment before the amount is read, in hledger as here, and a line
    /// break has ended the line, so neither can reach this.
    static func quotedSymbol(opening text: Substring, raw: String) throws -> (symbol: String, rest: Substring)? {
        guard text.first == "\"" else { return nil }
        let content = text.dropFirst()
        guard let closing = content.firstIndex(of: "\"") else { throw LedgerError.invalidAmount(raw) }
        return (String(content[..<closing]), content[content.index(after: closing)...])
    }

    /// Whether a symbol can be written bare and read back whole, which is
    /// hledger's rule for an unquoted symbol: no digit, no whitespace, and
    /// none of `-+.@*{}="`. Read bare, each of those is something else, a
    /// number, the end of the symbol, a price, an assertion or a quote, so
    /// `100 E R`, `E*R100` and `100 E-R` are no amount, as they are none in
    /// hledger, and a rebuilt amount writes such a symbol in quotes (issue
    /// #112). Every other character is the symbol's own in both tools:
    /// `E(R)`, `E!R`, `E/R`, `E:R`, `E'R` and `E,R` read bare, the last
    /// behind the number alone, since a comma opens a number in front of one
    /// here. The `;` is not in the list because the comment has opened
    /// before a symbol is read, and a stray `\r` is left in for
    /// `Transaction.init` to refuse by name, as it refuses one in every
    /// field, which says more than an invalid amount would.
    static func isBareSymbol(_ symbol: String) -> Bool {
        !symbol.contains { $0 != "\r" && ($0.isASCIIDigit || $0.isWhitespace || nonsimple.contains($0)) }
    }

    private static let nonsimple: Set<Character> = ["-", "+", ".", "@", "*", "{", "}", "=", "\""]

    /// The symbol as a posting line writes it: in double quotes when a bare
    /// symbol could not hold it, bare otherwise.
    ///
    /// The comma is quoted as well, since it opens a number here where
    /// hledger reads it as part of a bare symbol. Quoting a symbol hledger
    /// would write bare costs nothing, since it reads the quoted form the
    /// same, where a bare symbol it does not read leaves a file it refuses.
    /// A symbol holding a quote or a `;` is one no quoting writes;
    /// `Transaction.init` refuses it before it gets here.
    static func written(symbol: String) -> String {
        isBareSymbol(symbol) && !symbol.contains(",") ? symbol : "\"\(symbol)\""
    }
}

extension StringProtocol {
    /// The first character satisfying `predicate` that stands outside double
    /// quotes, or `nil`. What a quoted symbol holds is the symbol's, so a
    /// scan for an operator or a digit on the line skips it.
    func firstIndex(outsideQuotes predicate: (Character) -> Bool) -> Index? {
        var quoted = false
        // The label is spelled out: a trailing closure here resolves to this
        // very method, and the scan recursed until the stack ran out.
        return firstIndex(where: { character in
            if character == "\"" { quoted.toggle() }
            return !quoted && predicate(character)
        })
    }
}
